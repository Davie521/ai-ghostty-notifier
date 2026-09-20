import AppKit
import Foundation
import NotifyCore
import UserNotifications

/// The resident app. One process serves every Claude session on the machine:
/// it owns the notification center, subscribes to app-activation events instead
/// of polling for them, and answers clicks by driving Ghostty over Apple Events.
///
/// Nothing here decides *whether* to withdraw a notification — that lives in
/// `NotifyCore.SessionState` so the rules can be tested without a run loop.
@MainActor
final class Agent: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let paths: AgentPaths
    private let readiness: ResidentReadiness
    private let notifier: Notifier
    private var state = SessionState()
    private var spool: SpoolWatcher?
    private var pruneTimer: DispatchSourceTimer?
    private var activationObserver: NSObjectProtocol?
    private var terminationSource: DispatchSourceSignal?
    private var menuBar: MenuBar?
    private var permission: NotificationPermission = .unknown
    private var alertStyle = ""
    private var lastActivatedBundleID: String?
    private var shuttingDown = false
    /// Per-identifier expiry timers, so a replacement notification restarts the
    /// clock instead of inheriting the old one's deadline.
    private var expiryTimers: [String: DispatchSourceTimer] = [:]
    private let terminalBinding: NativeTerminalBinding
    private lazy var hookProcessor = HookProcessor(
        binding: terminalBinding,
        onPrompt: { [weak self] event, tab in
            guard let self else { return }
            self.state.captureOwner(sessionID: event.key, owner: event.owner)
            self.state.anchor(sessionID: event.key, tabID: tab, now: event.occurredAt)
            if event.options.clearOnFocus {
                let identifiers = self.state.takePreviousRoundNotifications(
                    sessionID: event.key, roundID: event.roundID)
                self.cancelExpiry(identifiers)
                self.notifier.withdraw(identifiers)
                self.withdrawLegacyCodex(sessionID: event.sessionID, source: event.source)
            }
            self.stateChanged()
        },
        onNotify: { [weak self] _, notify in
            self?.handle(.notify(notify))
        },
        log: { [weak self] in self?.log($0) })

    init(paths: AgentPaths) {
        self.paths = paths
        self.readiness = ResidentReadiness(paths: paths)
        let logPath = paths.log
        self.notifier = Notifier(log: { AgentLog.append($0, to: logPath) })
        let external = ExternalNotifications(
            automation: MacTerminalAutomation(),
            log: { AgentLog.append($0, to: logPath) })
        self.terminalBinding = NativeTerminalBinding(
            automation: MacTerminalAutomation(),
            clear: { event in await external.clear(event) },
            log: { AgentLog.append($0, to: logPath) })
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? PrivateFile.createDirectory(paths.root)
        // Earlier versions created these open to every local account.
        for directory in paths.ownedDirectories(
            codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"])
        {
            PrivateFile.closeDirectory(directory)
        }
        writePidFile()
        try? readiness.publishCapabilities(pid: getpid())
        loadState()
        log("agent up pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "<none>")")

        notifier.setDelegate(self)
        notifier.registerCategories()
        notifier.requestAuthorization { [weak self] answer in
            guard let self, !self.shuttingDown else { return }
            // Publish the answer: until this file says "authorized", the hooks
            // must not treat a spooled request as a delivered notification, or a
            // user who clicked "Don't Allow" would silently get nothing at all.
            // The three values matter to the install script, which retries an
            // "error" (the system never showed the dialog) but must not retry a
            // "denied" (the user answered, and macOS holds it against the
            // bundle identifier for good).
            switch answer {
            case .granted:
                self.permission = .granted
                self.log("authorization granted=true")
                self.publishReadiness(AgentConstants.readyAuthorized)
                self.publishAlertStyle()
                // Only now: an unauthorized center reports nothing delivered,
                // and reconciling against that would discard every restored
                // session's bookkeeping.
                self.reconcileWithNotificationCenter()
            case .denied:
                self.permission = .denied
                self.log("authorization granted=false")
                self.publishReadiness(AgentConstants.readyDenied)
                self.log("notifications are not authorized — see System Settings › Notifications")
            case .unavailable:
                self.permission = .unavailable
                self.publishReadiness(AgentConstants.readyError)
                self.log(
                    "authorization request was not processed; no dialog was shown — a relaunch can succeed"
                )
            }
            // The answer is the difference between an icon that means "working"
            // and one that means "nothing will ever appear". It arrives
            // asynchronously, well after the icon was first drawn.
            self.menuBar?.refresh()
        }

        observeActivation()
        startPruning()
        handleTermination()
        installMenuBar()

        let watcher = SpoolWatcher(
            directory: paths.spool,
            log: { [weak self] in self?.log($0) },
            onRequest: { [weak self] in self?.handle($0) }
        )
        watcher.start()
        spool = watcher
    }

    /// Turn SIGTERM into an orderly shutdown.
    ///
    /// launchd stops the agent with SIGTERM, and the default disposition kills
    /// the process outright — `applicationWillTerminate` never runs, so the
    /// pidfile and the readiness marker are left claiming a live, authorized
    /// agent. `agent_ready` in the hooks checks the process too, so nothing
    /// misroutes because of it, but a liveness marker that outlives the process
    /// it describes is a trap for the next reader.
    private func handleTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Agent.requestTermination()
            }
        }
        source.resume()
        terminationSource = source
    }

    /// `terminateLater` runs a nested AppKit loop. Enter it from the run loop,
    /// not from a main-dispatch callback which would keep the queue occupied
    /// and prevent the MainActor cleanup task from ever running.
    static func requestTermination() {
        NSApp.perform(
            #selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0,
            inModes: [.common])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shuttingDown else { return .terminateLater }
        shuttingDown = true
        // Redirect new hooks to the native worker before stopping consumption.
        // Retain the PID until cleanup ends so a second resident cannot enter.
        readiness.close()
        spool?.stop()
        Task {
            await hookProcessor.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveState()
        try? FileManager.default.removeItem(atPath: paths.pidFile)
        // Readiness is about a live agent, so it must not outlive the process:
        // a stale "authorized" would keep hooks routing into a dead spool.
        readiness.close()
        log("agent down")
    }

    // MARK: - Requests

    private func withdrawLegacyCodex(sessionID: String, source: HookSource) {
        // Older agents keyed Codex notices by the raw UUID. Retire that old
        // notice when its native replacement arrives, without touching Claude.
        guard source == .codex,
            state.sessions[sessionID]?.title.hasPrefix("Codex ") == true
        else { return }
        let ids = state.takeNotifications(sessionID: sessionID)
        cancelExpiry(ids)
        notifier.withdraw(ids)
    }

    private func handle(_ request: AgentRequest) {
        guard !shuttingDown else { return }
        switch request {
        case .hookEvent(let event):
            hookProcessor.receive(event)
        case .notify(let notify):
            withdrawLegacyCodex(sessionID: notify.sessionID, source: notify.source)
            state.captureOwner(sessionID: notify.stateKey, owner: notify.owner)
            // A tab id supplied by the hook is authoritative: it came from the
            // marker round-trip, which is correct regardless of what is focused
            // now. Record it before deciding anything.
            state.anchor(sessionID: notify.stateKey, tabID: notify.tabID, now: Agent.now())
            deliver(notify)
            shortenIfAlreadyWatching(notify)

        case .dismiss(let sessionID, let source):
            withdrawLegacyCodex(sessionID: sessionID, source: source)
            let key = source == .claude ? sessionID : "codex-" + sessionID
            let identifiers = state.takeNotifications(sessionID: key)
            cancelExpiry(identifiers)
            notifier.withdraw(identifiers)
            stateChanged()

        case .anchor(let rawSessionID, let tabID, let source):
            let sessionID = source == .claude ? rawSessionID : "codex-" + rawSessionID
            if let tabID {
                state.anchor(sessionID: sessionID, tabID: tabID, now: Agent.now())
                log("anchored \(sessionID) -> \(tabID)")
                stateChanged()
            } else {
                // No id from the hook (tmux, or the marker round-trip never
                // succeeded). Sampling the focused tab is a guess — the drain
                // can run a second after the prompt was submitted — so it only
                // fills a gap, never overwrites a known id.
                let known = state.sessions[sessionID]?.tabID
                guard known == nil else {
                    state.anchor(sessionID: sessionID, tabID: known, now: Agent.now())
                    stateChanged()
                    return
                }
                Ghostty.selectedTabID { [weak self] selected in
                    guard let self else { return }
                    self.state.anchor(
                        sessionID: sessionID, tabID: selected, now: Agent.now())
                    self.log("anchored \(sessionID) -> \(selected ?? "<unknown>") (sampled)")
                    self.stateChanged()
                }
            }

        case .ping:
            log("pong")

        case .styleHint:
            offerStyleGuidance(force: true)
        }
    }

    /// Restores the shell watcher's "already staring at it" clear.
    ///
    /// No activation event ever fires when the user watched the round finish in
    /// the session's own tab, because Ghostty never stopped being frontmost — so
    /// without this the notification would sit there until a prompt or a click.
    ///
    /// The notification is posted first and only its expiry is shortened, rather
    /// than suppressed outright: the shell path played the sound and then
    /// removed the banner about a second later, and swallowing the request
    /// entirely would take the audible cue with it. Three seconds is the grace
    /// Ghostty itself uses for a notification raised on an already-focused
    /// surface, and posting first keeps the banner immediate — the Apple Event
    /// happens after delivery, never in front of it.
    private func shortenIfAlreadyWatching(_ notify: NotifyRequest) {
        guard notify.clearOnFocus,
            frontmostIsGhostty,
            let tabID = state.sessions[notify.stateKey]?.tabID
        else { return }

        let identifier = SessionState.notificationID(sessionID: notify.stateKey)
        let postedAt = state.sessions[notify.stateKey]?.postedAt
        Ghostty.selectedTabID { [weak self] selected in
            guard let self, let selected, selected == tabID, self.frontmostIsGhostty,
                self.state.sessions[notify.stateKey]?.postedAt == postedAt
            else { return }
            self.log("\(notify.sessionID) is already on screen; clearing in short order")
            self.scheduleExpiry(identifier: identifier, after: Agent.watchedGraceSeconds)
            self.saveState()
        }
    }

    private static let watchedGraceSeconds: Double = 3
    private static let systemSettingsBundleID = "com.apple.systempreferences"
    /// How long after posting a notification is left out of reconciliation.
    private static let deliverySettleSeconds: Double = 5

    private func deliver(_ notify: NotifyRequest) {
        let identifier = state.newNotification(
            sessionID: notify.stateKey,
            clearOnFocus: notify.clearOnFocus,
            // Kept so the menu bar can name this session rather than counting
            // it. The hook already builds all three; nothing new crosses the
            // wire for them.
            title: notify.title,
            subtitle: notify.subtitle,
            body: notify.body,
            now: Agent.now(), roundID: notify.roundID)
        notifier.post(identifier: identifier, sessionID: notify.stateKey, request: notify)
        log("posted \(identifier)")
        scheduleExpiry(identifier: identifier, after: notify.timeout)
        stateChanged()
    }

    /// Mirrors the shell path's `--timeout`: without it a notification for a
    /// session the user never returns to would sit in Notification Center until
    /// the 24h prune, rather than the documented GHOSTTY_NOTIFY_TIMEOUT.
    private func scheduleExpiry(identifier: String, after seconds: Double?) {
        expiryTimers.removeValue(forKey: identifier)?.cancel()
        let owner = state.sessionID(forNotification: identifier)
        let lasting = seconds.map { $0 > 0 } ?? false
        // The deadline goes into the state, and with it to disk: the timer
        // below does not outlive this process, the notification does.
        if let owner {
            state.setExpiry(sessionID: owner, at: lasting ? Agent.now() + (seconds ?? 0) : nil)
        }
        guard let seconds, lasting, let owner, let postedAt = state.sessions[owner]?.postedAt
        else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let sessionID = self.state.sessionID(forNotification: identifier),
                    self.state.sessions[sessionID]?.postedAt == postedAt
                else {
                    return
                }
                self.expiryTimers.removeValue(forKey: identifier)
                let identifiers = self.state.takeNotifications(sessionID: sessionID)
                self.notifier.withdraw(identifiers)
                self.log("expired \(identifier)")
                self.stateChanged()
            }
        }
        timer.resume()
        expiryTimers[identifier] = timer
    }

    private func cancelExpiry(_ identifiers: [String]) {
        for identifier in identifiers {
            expiryTimers.removeValue(forKey: identifier)?.cancel()
        }
    }

    // MARK: - Focus

    private var frontmostIsGhostty: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == AgentConstants.ghosttyBundleID
    }

    /// The replacement for the shell version's one-second poll loop. macOS tells
    /// us when an app comes forward; between events this process is idle and
    /// spawns nothing.
    private func observeActivation() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Reduce to a Sendable value before crossing: the notification and
            // its NSRunningApplication must not follow us onto the main actor.
            let app =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.activated(bundleID: bundleID)
            }
        }
    }

    private func activated(bundleID: String?) {
        // Coming back from System Settings is when its answer may have changed.
        if lastActivatedBundleID == Agent.systemSettingsBundleID, bundleID != lastActivatedBundleID
        {
            refreshSettings()
        }
        lastActivatedBundleID = bundleID
        guard bundleID == AgentConstants.ghosttyBundleID else { return }
        withdrawForGhostty(retriesLeft: 1)
    }

    private func withdrawForGhostty(retriesLeft: Int) {
        // Cheap guard first. Asking Ghostty which tab is selected is an Apple
        // Event round-trip, and the first one raises the Automation consent
        // dialog — neither belongs on a plain Cmd-Tab with nothing on screen.
        guard state.hasOutstandingNotifications else { return }

        let asked = state.outstanding()
        Ghostty.selectedTabID { [weak self] selected in
            // The answer can take seconds. By then the user may have left
            // Ghostty again, and a round may have finished meanwhile: neither
            // that departure nor that notification is covered by the answer.
            guard let self, self.frontmostIsGhostty else { return }
            let identifiers = self.state.takeNotifications(
                for: .ghosttyActivated(selectedTabID: selected), among: asked)
            if !identifiers.isEmpty {
                self.cancelExpiry(identifiers)
                self.notifier.withdraw(identifiers)
                self.stateChanged()
                return
            }
            // Ghostty's scripting state can trail the activation by a few
            // milliseconds, so a query issued the instant it comes forward may
            // name the previously selected tab. One retry covers that without
            // reintroducing a poll.
            guard retriesLeft > 0, self.state.hasOutstandingNotifications else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.withdrawForGhostty(retriesLeft: retriesLeft - 1)
            }
        }
    }

    // MARK: - Clicks

    /// The notification center does not promise which thread it delivers a
    /// response on — Ghostty shipped a fix for exactly that hazard (its PR #7531,
    /// point 4). So this stays `nonisolated`, reduces the response to Sendable
    /// values, and hops to the main actor before touching any state.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let sessionID = response.notification.request.content.userInfo["session_id"] as? String
        let tabID = response.notification.request.content.userInfo["tab_id"] as? String
        let finish = UncheckedBox(completionHandler)
        Task { @MainActor in
            self.clicked(identifier: identifier, action: action, sessionID: sessionID, tabID: tabID)
            finish.value()
        }
    }

    private func clicked(identifier: String, action: String, sessionID: String?, tabID: String?) {
        // Fall back to the bookkeeping when userInfo is unavailable, so a click
        // still routes after an upgrade that changed the payload.
        let session = sessionID ?? state.sessionID(forNotification: identifier)
        state.forgetNotification(identifier)
        cancelExpiry([identifier])
        stateChanged()

        switch action {
        case UNNotificationDismissActionIdentifier:
            // Closing a notification is not a request to go anywhere. The
            // retired alerter backend had exactly this bug: its close-button
            // label was matched as an action and phantom-activated Ghostty.
            log("dismissed \(identifier)")
        case UNNotificationDefaultActionIdentifier, AgentConstants.gotoActionID:
            jump(sessionID: session, fallbackTabID: tabID)
        default:
            log("ignored action \(action) on \(identifier)")
        }
    }

    /// Present the banner even while we are frontmost. As an accessory app we
    /// are never meaningfully "in front", but the notification a user asked for
    /// should not depend on that. Touches no state, so it answers inline.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) ->
            Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func jump(sessionID: String?, fallbackTabID: String? = nil) {
        // Prefer live bookkeeping, then the id ghostty-tab-save.sh persisted —
        // which survives an agent that lost its state file.
        var tabID = sessionID.flatMap { state.sessions[$0]?.tabID }
        if tabID == nil, let sessionID {
            tabID = Agent.persistedTabID(paths: paths, sessionID: sessionID)
        }
        if tabID == nil { tabID = fallbackTabID }
        guard let tabID else {
            // No tab was ever resolved (tmux, unscriptable Ghostty). Front the
            // app so the user is one keystroke away instead of nowhere.
            log("jump: no tab for \(sessionID ?? "<none>"), activating Ghostty")
            NSApp.activate(ignoringOtherApps: true)
            Ghostty.activate()
            return
        }
        // Focusing the terminal raises its window and selects its tab together.
        // Do not issue a second app-wide activation after success: it can put
        // the previously active window back in front of the verified target.
        Ghostty.focus(tabID: tabID) { [weak self] selected in
            guard let self else { return }
            switch selected {
            case nil:
                Ghostty.activate()
                self.log("jump: \(tabID) not found, activated Ghostty only")
            case tabID:
                self.log("jump: focused \(tabID), verified selected")
            case .some(let other):
                Ghostty.activate()
                // Selecting reported success but the selection did not stick.
                // Worth its own line: it is the difference between "we asked"
                // and "it happened", and the two look identical from outside.
                self.log("jump: asked for \(tabID) but \(other) is selected")
            }
        }
    }

    /// Reads the tab id ghostty-tab-save.sh wrote for a session.
    private static func persistedTabID(paths: AgentPaths, sessionID: String) -> String? {
        guard RequestCodec.isValidSessionID(sessionID) else { return nil }
        let path = paths.sessionTabFile(sessionID: sessionID)
        guard let data = FileManager.default.contents(atPath: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tabID = object["tab_id"] as? String,
            !tabID.isEmpty
        else { return nil }
        return tabID
    }

    // MARK: - Housekeeping

    /// Drop bookkeeping for notifications macOS no longer has on screen.
    ///
    /// The user can clear one from Notification Center. `.customDismissAction`
    /// catches that while this process is running; nothing catches a "Clear All"
    /// performed while the agent was down, and `loadState` then re-adopts
    /// identifiers for notifications that no longer exist. That used to be
    /// invisible — now it is a count on the menu bar insisting something is
    /// waiting when nothing is.
    private func reconcileWithNotificationCenter() {
        guard state.hasOutstandingNotifications else { return }
        // Not the newest: a notification handed to the center a moment ago may
        // not be listed as delivered yet, and one posted while the list is on
        // its way is not in it at all.
        let asked = state.outstanding(postedBefore: Agent.now() - Agent.deliverySettleSeconds)
        notifier.deliveredIdentifiers { [weak self] delivered in
            guard let self else { return }
            let gone = self.state.forgetNotifications(notIn: delivered, among: asked)
            guard !gone.isEmpty else { return }
            self.cancelExpiry(gone)
            self.log("reconciled: \(gone.joined(separator: ",")) no longer on screen")
            self.stateChanged()
        }
    }

    private func startPruning() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3600, repeating: 3600, leeway: .seconds(300))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let orphaned = self.state.prune(
                    maxAge: AgentConstants.sessionMaxAge, now: Agent.now())
                self.cancelExpiry(orphaned)
                self.notifier.withdraw(orphaned)
                self.stateChanged()
                // Catches a notification cleared during a long idle stretch, so
                // the count cannot drift for a whole day.
                self.reconcileWithNotificationCenter()
                self.refreshSettings()
            }
        }
        timer.resume()
        pruneTimer = timer
    }

    private func writePidFile() {
        try? "\(getpid())\n".write(toFile: paths.pidFile, atomically: true, encoding: .utf8)
    }

    /// Record the notification style and, when it is Banner, say plainly what
    /// that costs and how to change it.
    ///
    /// Banner notifications slide away after about five seconds. Clicking one is
    /// how you jump to the session's tab, so on Banner the jump is only reachable
    /// through Notification Center. No app can change this: Apple removed the
    /// ability, and only built-in apps get Alerts by default. Detecting it and
    /// pointing at the exact pane is the whole of what is available — which is
    /// what other apps in this position do.
    private func publishAlertStyle() {
        notifier.currentAlertStyle { [weak self] style in
            guard let self else { return }
            self.alertStyle = style
            try? (style + "\n").write(
                toFile: self.paths.alertStyleFile, atomically: true, encoding: .utf8)
            self.log("alert style = \(style)")
            // "none" is the one style the icon itself reports, so it has to be
            // redrawn once the answer is in.
            self.menuBar?.refresh()
            guard style == "banner" else { return }
            self.log(
                "temporary style: notifications slide away after a few seconds, so "
                    + "click-to-jump is only reachable from Notification Center. Fix at "
                    + "System Settings › Notifications › \(Self.appName) › Alert Style › "
                    + "Persistent  (deep link: \(Self.notificationSettingsURL))")
            self.offerStyleGuidance(force: false)
        }
    }

    /// Permission and style were read once, at launch, and then believed for
    /// as long as the agent ran. Both can change under it: the menu's Settings
    /// link exists to make the user change one. Until a restart the menu kept
    /// its warning, and, worse, the readiness file kept telling the hooks that
    /// the agent could display notifications after they had been switched off.
    /// Looked at again when the user leaves System Settings, when the menu
    /// opens, and hourly. This only reads: it never asks, and never reopens the
    /// style guidance.
    private func refreshSettings() {
        notifier.currentSettings { [weak self] authorized, style in
            guard let self, !self.shuttingDown else { return }
            var changed = false
            let permission = self.permission.updated(authorized: authorized)
            if permission != self.permission {
                self.permission = permission
                if let readiness = permission.readiness { self.publishReadiness(readiness) }
                self.log("notification permission is now \(permission)")
                changed = true
            }
            if style != self.alertStyle {
                self.alertStyle = style
                try? (style + "\n").write(
                    toFile: self.paths.alertStyleFile, atomically: true, encoding: .utf8)
                self.log("alert style is now \(style)")
                changed = true
            }
            if changed { self.menuBar?.refresh() }
        }
    }

    /// One-time guidance walking the user to the setting.
    ///
    /// A log line is not guidance for something the product does not work
    /// properly without, and this cannot be fixed in code — so the app has to
    /// ask. Shown at most once unless `force` (a `style_hint` request), because a
    /// login-launched background agent nagging on every restart would be worse
    /// than the problem.
    ///
    /// Deliberately a non-modal window: see StyleHintWindow for what an
    /// NSAlert.runModal() did to the rest of the agent.
    func offerStyleGuidance(force: Bool) {
        let marker = paths.styleHintShownFile
        if !force, FileManager.default.fileExists(atPath: marker) { return }
        try? "shown\n".write(toFile: marker, atomically: true, encoding: .utf8)

        StyleHintWindow.show(
            settingsURL: Self.notificationSettingsURL,
            appName: Self.appName,
            log: { [weak self] in self?.log($0) }
        )
    }

    /// The only always-visible surface the agent has. Without it, "running and
    /// working" and "running but unable to display anything" look identical from
    /// outside — which is the state an unanswered permission prompt or the
    /// Temporary alert style leaves it in.
    private func installMenuBar() {
        guard MenuBar.isEnabled(env: ProcessInfo.processInfo.environment) else {
            log("menu bar item disabled by GHOSTTY_NOTIFY_MENU_BAR")
            return
        }
        menuBar = MenuBar(
            // Two closures, because the two callers cost different amounts. The
            // icon is refreshed on every state change and needs a count;
            // building the rows allocates one value per session and sorts them,
            // and is only worth doing when the menu actually opens.
            iconState: { [weak self] in
                guard let self else { return .idle }
                return MenuBarState.resolve(
                    permission: self.permission,
                    alertStyle: self.alertStyle,
                    waiting: self.state.waitingCount)
            },
            menuStatus: { [weak self] in
                guard let self else {
                    return AgentStatus(
                        permission: .unknown, alertStyle: "", waiting: [], trackedSessions: 0)
                }
                return AgentStatus(
                    permission: self.permission,
                    alertStyle: self.alertStyle,
                    waiting: self.state.waitingSessions(),
                    trackedSessions: self.state.sessions.count
                )
            },
            onJump: { [weak self] sessionID in
                guard let self else { return }
                // Taking the notification down here rather than leaving it to
                // the activation observer: the row was the click, so the alert
                // has done its job whether or not Ghostty ends up frontmost —
                // and a session with no resolved tab would otherwise keep its
                // notification after the user has plainly dealt with it.
                let identifiers = self.state.takeNotifications(sessionID: sessionID)
                self.cancelExpiry(identifiers)
                self.notifier.withdraw(identifiers)
                self.stateChanged()
                self.log("menu: jumping to \(sessionID)")
                self.jump(sessionID: sessionID)
            },
            onShowGuidance: { [weak self] in self?.offerStyleGuidance(force: true) },
            onOpenSettings: { [weak self] in
                guard let url = URL(string: Agent.notificationSettingsURL) else { return }
                NSWorkspace.shared.open(url)
                self?.log("menu: opened notification settings")
            },
            onOpenLog: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: self.paths.log))
            },
            onOpen: { [weak self] in self?.refreshSettings() }
        )
    }

    private static let appName = "Claude Ghostty Notify"
    /// Opens System Settings straight at this app's own notification pane.
    static var notificationSettingsURL: String {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        return "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)"
    }

    private func publishReadiness(_ value: String) {
        try? readiness.publishAuthorization(value)
    }

    private func loadState() {
        guard let data = FileManager.default.contents(atPath: paths.state) else { return }
        state = StateCodec.decode(data)
        log("restored \(state.sessions.count) sessions")
        // Timeouts that ran out while no agent was running, then the rest.
        let (overdue, pending) = state.resumeExpiries(now: Agent.now())
        if !overdue.isEmpty {
            notifier.withdraw(overdue)
            log("expired while the agent was down: \(overdue.joined(separator: ","))")
        }
        for timer in pending {
            scheduleExpiry(identifier: timer.identifier, after: timer.remaining)
        }
        if !overdue.isEmpty { saveState() }
    }

    /// Persist bookkeeping and let the menu bar catch up.
    ///
    /// Every mutation goes through here so the icon can never disagree with what
    /// the agent knows. The alternative — refreshing only when the menu opens —
    /// is what made the icon a snapshot of the last time the user looked at it.
    private func stateChanged() {
        saveState()
        menuBar?.refresh()
    }

    private func saveState() {
        guard let data = try? StateCodec.encode(state) else { return }
        // Atomic: a crash mid-write must not leave bookkeeping that decodes to
        // half a truth. `Data.write(options: .atomic)` handles the
        // does-not-exist-yet case, which replaceItemAt does not.
        try? PrivateFile.write(data, to: paths.state)
    }

    private static func now() -> Double { Date().timeIntervalSince1970 }

    private func log(_ message: String) {
        AgentLog.append(message, to: paths.log)
    }
}

/// Carries a non-Sendable completion handler across an actor hop. Safe by usage,
/// not by type: each one is called exactly once, on the main actor.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
