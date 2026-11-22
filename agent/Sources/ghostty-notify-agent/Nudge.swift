import Foundation
import NotifyCore

/// `ghostty-notify-agent --nudge <message>`: the coding agent, Claude Code or
/// Codex CLI, calls the user back to its session. The content and the messages
/// live in NotifyCore's `NudgeNotification`; this finds what the session's
/// hooks already recorded (its tab, its round, its folder) and its title, and
/// hands the notification to the resident agent.
///
/// Read-only towards the terminal: the tab is the one the hooks bound, never a
/// marker round-trip, which needs the session's own terminal, and this process
/// runs in a shell the CLI started without one.
@MainActor
enum Nudge {
    static let titleSeconds = 4.0

    static func run(arguments: [String], environment: [String: String], paths: AgentPaths) async
        -> Int32
    {
        let (noReturn, words) = NudgeNotification.parse(arguments)
        guard let message = NudgeNotification.message(words) else {
            SelfTest.fail(NudgeNotification.usage)
            return 2
        }
        // Not delivered, so not exit 0: the skill reads 0 as delivered and
        // has the agent wait for the user's step.
        if NudgeNotification.insideTmux(environment) {
            SelfTest.fail(NudgeNotification.skippedInTmux)
            return 1
        }
        let app = Bundle.main.bundlePath
        let nearest = HookProcessContext.nearest(among: [.claude, .codex])
        guard let session = NudgeNotification.session(environment: environment, nearest: nearest)
        else {
            SelfTest.fail(NudgeNotification.explain(.noSession, app: app))
            return 1
        }
        let codexHome = Self.codexHome(environment: environment, home: paths.home)
        let settings = Self.settings(for: session.source, environment, codexHome: codexHome)
        guard
            var event = NativeHookRuntime.sessionEvent(
                sessionID: session.id, source: session.source, environment: settings,
                paths: paths)
        else {
            SelfTest.fail(NudgeNotification.explain(.noSession, app: app))
            return 1
        }
        let transport = HookTransport(paths: paths)
        if let problem = TestNotification.problem(
            running: transport.runningPID != nil,
            readiness: DiskRoundJournal.read(paths.readyFile))
        {
            SelfTest.fail(NudgeNotification.explain(.agent(problem), app: app))
            return 1
        }
        if noReturn, !transport.acceptsNoReturnNudges {
            SelfTest.fail(NudgeNotification.explain(.outdated, app: app))
            return 1
        }
        let (binding, _) = NativeHookRuntime.dependencies(paths: paths)
        let tab = await binding.existing(event)
        switch session.source {
        case .claude:
            event.payload.transcriptPath = transcript(
                sessionID: session.id, environment: environment, home: paths.home)
        case .codex:
            // Where the title lookup finds Codex's own database, as for its hooks.
            event.codexHome = codexHome
            event.codexSQLiteHome = settings["CODEX_SQLITE_HOME"].map {
                HookIntake.absolute(
                    $0, fallback: codexHome, home: paths.home,
                    cwd: FileManager.default.currentDirectoryPath)
            }
        }
        // A long transcript must not use up the time the wait for the agent,
        // and taking the nudge back, need before the 20-second deadline in
        // main.swift: past `titleSeconds` the nudge goes out untitled.
        let titled = event
        let title =
            (try? await QueryDeadline.run(seconds: titleSeconds) {
                await DiskSessionContent().title(for: titled)
            }) ?? ""
        var request = NudgeNotification.request(
            sessionID: session.id, source: session.source, message: message, title: title,
            project: project(event), tabID: tab, roundID: event.roundID,
            settings: event.settings, noReturn: noReturn)
        // No tab bound yet (a Codex session before its first long run): the
        // agent looks for the tab titled after the session instead.
        if tab == nil, !title.isEmpty { request.tabTitle = title }
        guard await hand(.notify(request), transport: transport, paths: paths, app: app) else {
            return 1
        }
        print(
            NudgeNotification.sent(
                tabKnown: tab != nil, lookedUp: request.tabTitle != nil, noReturn: noReturn))
        return 0
    }

    /// `--nudge-done`: the step the nudge asked for has happened, so take the
    /// nudge back. Only a nudge: should the run's completion notification have
    /// replaced it already, that one stays.
    static func done(environment: [String: String], paths: AgentPaths) async -> Int32 {
        let app = Bundle.main.bundlePath
        let nearest = HookProcessContext.nearest(among: [.claude, .codex])
        guard let session = NudgeNotification.session(environment: environment, nearest: nearest)
        else {
            SelfTest.fail(NudgeNotification.explain(.noSession, app: app))
            return 1
        }
        // Taking a notification back needs the app running, not allowed to post.
        let transport = HookTransport(paths: paths)
        guard transport.runningPID != nil else {
            SelfTest.fail(NudgeNotification.explain(.agent(.notRunning), app: app))
            return 1
        }
        guard transport.acceptsNoReturnNudges else {
            SelfTest.fail(NudgeNotification.explain(.outdated, app: app))
            return 1
        }
        let request = AgentRequest.dismissNudge(sessionID: session.id, source: session.source)
        guard await hand(request, transport: transport, paths: paths, app: app) else { return 1 }
        print("Done. The session's nudge, if it still showed one, is gone.")
        return 0
    }

    /// Queue `request` for the resident agent and wait for it to be taken;
    /// false, with the reason on stderr, when it was not.
    private static func hand(
        _ request: AgentRequest, transport: HookTransport, paths: AgentPaths, app: String
    ) async -> Bool {
        let file: String
        var sandboxed = false
        do {
            file = try transport.queue(request)
        } catch {
            // Codex CLI's sandbox refuses writes under ~/.claude. The agent
            // also reads nudges from a place the sandbox leaves open.
            guard let nudges = Self.nudgeSpool(paths),
                let queued = try? AtomicSpool.write(RequestCodec.encode(request), to: nudges)
            else {
                SelfTest.fail("Could not queue the request: \(error)")
                return false
            }
            file = queued
            sandboxed = true
        }
        if await !SelfTest.collected(file) {
            // Not taken: take it back, or an agent that recovers later acts on
            // a request the coding agent was told had not been sent, and the
            // user hears about the same thing twice.
            let done: Bool
            if case .dismissNudge = request { done = true } else { done = false }
            switch AtomicSpool.withdraw(file) {
            case .withdrawn:
                let problem: NudgeNotification.Problem =
                    done
                    ? .doneNotCollected
                    : sandboxed ? .notCollectedFromSandbox : .agent(.notCollected)
                SelfTest.fail(NudgeNotification.explain(problem, app: app))
                return false
            case .stuck(let reason):
                SelfTest.fail(
                    NudgeNotification.explain(done ? .doneStuck(reason) : .stuck(reason), app: app))
                return false
            case .taken: break  // The agent took it after all.
            }
        }
        return true
    }

    /// CODEX_HOME resolved as the hooks resolve it; ~/.codex when unset.
    private static func codexHome(environment: [String: String], home: String) -> String {
        HookIntake.absolute(
            environment["CODEX_HOME"].flatMap { $0.contains("\0") ? nil : $0 },
            fallback: home + "/.codex", home: home,
            cwd: FileManager.default.currentDirectoryPath)
    }

    /// The nudge spool the running agent says it watches, else where it would
    /// be: a sandbox may not let this process ask macOS for the directory.
    private static func nudgeSpool(_ paths: AgentPaths) -> String? {
        let published = DiskRoundJournal.read(paths.nudgeSpoolFile)
        if published.hasPrefix("/"), published != "/", !published.contains("\0") {
            return published
        }
        return paths.nudgeSpool
    }

    /// The settings the session's hooks run with. Codex CLI passes none of its
    /// own to commands, so its hooks read them from the config.json the
    /// installer wrote beside them; a nudge reads the same file, and goes out
    /// under Codex's name as its notifications do.
    private static func settings(
        for source: HookSource, _ environment: [String: String], codexHome: String
    ) -> [String: String] {
        guard source == .codex else { return environment }
        var settings = environment
        if let config = FileManager.default.contents(
            atPath: codexHome + "/ghostty-notify/config.json"),
            let merged = try? HookIntake.merging(config: config, environment: environment)
        {
            settings = merged
        }
        settings["GHOSTTY_NOTIFY_APP_NAME"] = "Codex"
        return settings
    }

    /// Claude Code keeps each session's transcript as
    /// `<config>/projects/<folder>/<session id>.jsonl`; its title is in there.
    private static func transcript(
        sessionID: String, environment: [String: String], home: String
    ) -> String? {
        let config =
            environment["CLAUDE_CONFIG_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? home + "/.claude"
        let projects = config + "/projects"
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: projects)
        else { return nil }
        return folders.lazy
            .map { projects + "/" + $0 + "/" + sessionID + ".jsonl" }
            .first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// The folder the session runs in, as its binding recorded it: the shell
    /// this runs in may have changed directory since.
    private static func project(_ event: HookEvent) -> String {
        let record = FileManager.default.contents(
            atPath: event.sessionDirectory + "/" + event.sessionID + ".json"
        ).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let folder =
            (record?["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: folder).lastPathComponent
    }
}
