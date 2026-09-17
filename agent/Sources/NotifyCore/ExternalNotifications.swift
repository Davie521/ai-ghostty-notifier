import Darwin
import Foundation

/// Only genuine actions can focus a terminal. Dismiss/timeout/empty/error
/// output intentionally do nothing, including newer alerter's "Dismiss".
public enum ExternalNotificationAction {
    public static func shouldFocus(_ output: String) -> Bool {
        ["Go to tab", "@CONTENTCLICKED"].contains(output.trimmingCharacters(in: .newlines))
    }
}

private struct ExternalNotice: Codable {
    var token: String
    var round: String
    var postedAt: Double
    var executable: String
    var modern: Bool
    var childPID: Int32?
    var childBirth: String?
}

/// Native compatibility adapter for optional notification backends. The
/// resident app uses clear(); a same-binary worker uses deliver(). TIMEOUT=0
/// explicitly allows an indefinite wait, but cancellation still reaps children.
/// The delivery lease protects group replacement and prompt cleanup across
/// processes; tokens prevent an old worker removing a replacement's notice.
public actor ExternalNotifications {
    private let launcher: any CommandLaunching
    private let inspector: any ProcessInspecting
    private let signaller: any ProcessSignalling
    private let automation: any TerminalAutomationProviding
    private let clock: any HookClockProviding
    private let log: @Sendable (String) -> Void
    public init(
        automation: any TerminalAutomationProviding,
        launcher: any CommandLaunching = NativeCommandLauncher(),
        inspector: any ProcessInspecting = MacProcessInspector(),
        signaller: any ProcessSignalling = MacProcessSignaller(),
        clock: any HookClockProviding = SystemHookClock(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.automation = automation
        self.launcher = launcher
        self.inspector = inspector
        self.signaller = signaller
        self.clock = clock
        self.log = log
    }
    private func path(_ event: HookEvent, _ suffix: String) -> String {
        event.sessionDirectory + "/" + event.sessionID + "." + suffix
    }
    private func current(_ event: HookEvent) -> Bool {
        DiskRoundJournal.read(path(event, "round")) == event.roundID
    }
    private func group(_ event: HookEvent) -> String {
        let prefix =
            event.settings["GHOSTTY_NOTIFY_GROUP_PREFIX"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (event.source == .codex ? "codex-ghostty-notify" : "ghostty-notify")
        return prefix + "-" + event.sessionID
    }
    private func notice(_ event: HookEvent) -> ExternalNotice? {
        FileManager.default.contents(atPath: path(event, "native-notice.json"))
            .flatMap { try? JSONDecoder().decode(ExternalNotice.self, from: $0) }
    }
    private func owns(_ event: HookEvent, _ token: String) -> Bool { notice(event)?.token == token }
    private func alerter(_ event: HookEvent) -> String? {
        let value =
            event.settings["GHOSTTY_NOTIFY_ALERTER"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ExecutableSearch.find("alerter", event: event)
        return value.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }
    private func modern(_ executable: String) async -> Bool {
        guard let child = try? launcher.start(executable: executable, arguments: ["--help"]) else {
            return false
        }
        return await child.result(timeout: 2).output.contains("--close-label")
    }
    private func remove(executable: String, modern: Bool, event: HookEvent) async {
        guard
            let child = try? launcher.start(
                executable: executable,
                arguments: [modern ? "--remove" : "-remove", group(event)])
        else { return }
        // Withdrawal is cleanup: let this bounded command finish even when
        // the delivery task was cancelled while its banner was visible.
        _ = await Task { await child.result(timeout: 2) }.value
    }
    private func stop(
        pid: Int32?, birth: String?, event: HookEvent, watcher: Bool = false,
        executable: String? = nil
    ) {
        guard let pid, pid > 1, pid != getpid(), let process = inspector.process(pid),
            birth == nil || process.birth == birth
        else { return }
        let args = inspector.arguments(pid)
        let valid: Bool
        if watcher {
            valid =
                args.contains {
                    URL(fileURLWithPath: $0).lastPathComponent == "ghostty-notify-clear.sh"
                }
                && zip(args, args.dropFirst()).contains { $0 == "--watch" && $1 == event.sessionID }
        } else {
            let sameExecutable =
                executable.map {
                    URL(fileURLWithPath: process.executable).resolvingSymlinksInPath().path
                        == URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                } ?? (URL(fileURLWithPath: process.executable).lastPathComponent == "alerter")
            valid =
                sameExecutable
                && zip(args, args.dropFirst()).contains {
                    ($0 == "--group" || $0 == "-group") && $1 == group(event)
                }
        }
        // Re-read birth immediately before signalling: never trust a stale PID
        // file or a substring match on another session's command line.
        if valid, inspector.process(pid)?.birth == process.birth { signaller.terminate(pid) }
    }

    public func clear(_ event: HookEvent, force: Bool = false) async {
        guard force || event.options.clearOnFocus, current(event),
            let lease = DirectoryLease.acquire(path(event, "delivery-lock"), timeout: 5)
        else { return }
        defer { lease.release() }
        guard current(event) else { return }
        if let record = notice(event) {
            // Same-round Notification may already have overtaken this prompt.
            guard force || (record.round != event.roundID && record.postedAt <= event.occurredAt)
            else { return }
            await remove(executable: record.executable, modern: record.modern, event: event)
            stop(
                pid: record.childPID, birth: record.childBirth, event: event,
                executable: record.executable)
            try? FileManager.default.removeItem(atPath: path(event, "native-notice.json"))
        }
        await clearLegacy(event)
    }

    private func clearLegacy(_ event: HookEvent) async {
        let pidFile = path(event, "alerter-pid")
        let stamp = path(event, "legacy-cleared")
        let legacyPIDExists = ["alerter-pid", "watch-pid"].contains {
            FileManager.default.fileExists(atPath: path(event, $0))
        }
        if !legacyPIDExists, FileManager.default.fileExists(atPath: stamp) { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: pidFile),
            let date = attrs[.modificationDate] as? Date,
            date.timeIntervalSince1970 > event.occurredAt
        {
            return
        }
        for suffix in ["watch-pid", "alerter-pid"] {
            stop(
                pid: Int32(DiskRoundJournal.read(path(event, suffix))), birth: nil,
                event: event, watcher: suffix == "watch-pid")
            try? FileManager.default.removeItem(atPath: path(event, suffix))
        }
        // terminal-notifier never wrote a PID. Check both legacy senders even
        // when there is no PID file, but only once per migrated session; an absent group
        // is a no-op. All calls are bounded and receive EOF on stdin.
        if let executable = alerter(event) {
            let dialect = await modern(executable)
            await remove(executable: executable, modern: dialect, event: event)
        }
        if let executable = ExecutableSearch.find("terminal-notifier", event: event) {
            await remove(executable: executable, modern: false, event: event)
        }
        try? "cleared\n".write(toFile: stamp, atomically: true, encoding: .utf8)
    }

    public func deliver(_ request: NotifyRequest, event: HookEvent) async {
        guard !Task.isCancelled, current(event), clock.now() < event.expiresAt else { return }
        let backend = event.options.backend
        let preferAlerter = !["agent", "terminal-notifier"].contains(backend)
        let executable =
            (preferAlerter ? alerter(event) : nil)
            ?? ExecutableSearch.find("terminal-notifier", event: event)
        guard let executable else {
            log("no usable notification backend; install/authorize the native agent")
            return
        }
        let isAlerter = preferAlerter && executable == alerter(event)
        let dialect = isAlerter ? await modern(executable) : false
        guard !Task.isCancelled, current(event), clock.now() < event.expiresAt,
            let lease = DirectoryLease.acquire(path(event, "delivery-lock"), timeout: 5)
        else { return }
        guard current(event) else {
            lease.release()
            return
        }
        if let old = notice(event) {
            // Retire its blocking process before reusing the same group ID.
            stop(pid: old.childPID, birth: old.childBirth, event: event, executable: old.executable)
        }
        let prefix = dialect ? "--" : "-"
        func value(_ text: String) -> String { String(text.drop(while: { $0 == "-" })) }
        var args = [
            prefix + "title", value(request.title), prefix + "subtitle", value(request.subtitle),
            prefix + "message", value(request.body), prefix + "group", group(event),
        ]
        if isAlerter {
            args += [
                prefix + "actions", "Go to tab", prefix + "timeout",
                String(format: "%.0f", request.timeout ?? 0),
                dialect ? "--close-label" : "-closeLabel", "Dismiss",
            ]
        }
        if let sound = request.sound { args += [prefix + "sound", sound] }
        let child: any RunningCommand
        do { child = try launcher.start(executable: executable, arguments: args) } catch {
            lease.release()
            log("notification backend failed to launch: \(error)")
            if isAlerter { await fallback(request, event: event) }
            return
        }
        let record = ExternalNotice(
            token: UUID().uuidString, round: event.roundID,
            postedAt: clock.now(), executable: executable, modern: dialect,
            childPID: isAlerter ? child.pid : nil, childBirth: inspector.process(child.pid)?.birth)
        do {
            try JSONEncoder().encode(record).write(
                to: URL(fileURLWithPath: path(event, "native-notice.json")), options: .atomic)
        } catch {
            child.cancel()
            lease.release()
            _ = await child.result(timeout: 1)
            log("cannot track external notification: \(error)")
            return
        }
        lease.release()

        // Native worker, not a shell watcher. Positive bounded polling exists
        // only for external backends; the resident UN backend is event-driven.
        let lifetime = request.timeout.map { min($0, 86400 * 365) + 30 }
        // Structured lifetime: cancelling delivery also cancels and reaps the
        // blocking backend, including TIMEOUT=0 and clear-on-focus opt-out.
        async let result = child.result(timeout: isAlerter ? lifetime : 5)
        if !isAlerter, await result.status != 0 {
            log("terminal-notifier failed; no focus watcher was started")
            await withdraw(event, record: record)
            return
        }
        if request.clearOnFocus {
            let configured = Double(event.settings["GHOSTTY_NOTIFY_FOCUS_POLL"] ?? "1") ?? 1
            let poll = configured.isFinite && configured > 0 ? max(0.1, configured) : 1
            let deadline = lifetime.map { clock.now() + $0 } ?? .infinity
            var sawAway = await automation.isFrontmost() == false
            while clock.now() < deadline, owns(event, record.token), !Task.isCancelled {
                if isAlerter, !child.isRunning { break }
                let front = await automation.isFrontmost()
                if front == false { sawAway = true }
                let selected =
                    front == true && request.tabID != nil ? await automation.selectedTabID() : nil
                if front == true, request.tabID != nil ? selected == request.tabID : sawAway {
                    await withdraw(event, record: record)
                    break
                }
                do { try await clock.sleep(seconds: poll) } catch { break }
                if !isAlerter, !child.isRunning, await result.status != 0 { break }
            }
        }
        if !owns(event, record.token) { child.cancel() }
        let response = await result
        let failedWhileOwned = response.status != 0 && owns(event, record.token)
        if !Task.isCancelled, isAlerter, response.status == 0, owns(event, record.token),
            ExternalNotificationAction.shouldFocus(response.output)
        {
            await automation.focus(tabID: request.tabID)
        } else if response.status != 0 {
            log("external notification backend exited \(response.status)")
        }
        // Keep terminal-notifier's record while it may still be visible, so a
        // later prompt can remove it even after this bounded worker has exited.
        if isAlerter || Task.isCancelled { await withdraw(event, record: record) }
        if !Task.isCancelled, isAlerter, failedWhileOwned { await fallback(request, event: event) }
    }

    private func fallback(_ request: NotifyRequest, event: HookEvent) async {
        var fallback = event
        fallback.settings["GHOSTTY_NOTIFY_BACKEND"] = "terminal-notifier"
        await deliver(request, event: fallback)
    }

    private func withdraw(_ event: HookEvent, record: ExternalNotice) async {
        guard let lease = DirectoryLease.acquire(path(event, "delivery-lock"), timeout: 5) else {
            return
        }
        defer { lease.release() }
        guard owns(event, record.token) else { return }
        await remove(executable: record.executable, modern: record.modern, event: event)
        stop(
            pid: record.childPID, birth: record.childBirth, event: event,
            executable: record.executable)
        try? FileManager.default.removeItem(atPath: path(event, "native-notice.json"))
    }
}
