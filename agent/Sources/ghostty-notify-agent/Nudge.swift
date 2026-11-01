import Foundation
import NotifyCore

/// `ghostty-notify-agent --nudge <message>`: the coding agent calls the user
/// back to its session. The content and the messages live in NotifyCore's
/// `NudgeNotification`; this finds what the session's hooks already recorded
/// (its tab, its round, its folder) and its title, and hands the notification
/// to the resident agent.
///
/// Read-only towards the terminal: the tab is the one the hooks bound, never a
/// marker round-trip, which needs the session's own terminal, and this process
/// runs in a shell the CLI started without one.
@MainActor
enum Nudge {
    static let titleSeconds = 4.0

    static func run(words: [String], environment: [String: String], paths: AgentPaths) async
        -> Int32
    {
        guard let message = NudgeNotification.message(words) else {
            SelfTest.fail(NudgeNotification.usage)
            return 2
        }
        let app = Bundle.main.bundlePath
        guard let sessionID = NudgeNotification.sessionID(environment: environment),
            var event = NativeHookRuntime.sessionEvent(
                sessionID: sessionID, environment: environment, paths: paths)
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
        let (binding, _) = NativeHookRuntime.dependencies(paths: paths)
        let tab = await binding.existing(event)
        event.payload.transcriptPath = transcript(
            sessionID: sessionID, environment: environment, home: paths.home)
        // A long transcript must not use up the time the wait for the agent,
        // and taking the nudge back, need before the 20-second deadline in
        // main.swift: past `titleSeconds` the nudge goes out untitled.
        let titled = event
        let title =
            (try? await QueryDeadline.run(seconds: titleSeconds) {
                await DiskSessionContent().title(for: titled)
            }) ?? ""
        let request = NudgeNotification.request(
            sessionID: sessionID, message: message, title: title, project: project(event),
            tabID: tab, roundID: event.roundID, settings: event.settings)
        let file: String
        do {
            file = try transport.queue(.notify(request))
        } catch {
            SelfTest.fail("Could not queue the nudge: \(error)")
            return 1
        }
        if await !SelfTest.collected(file) {
            // Not taken: take it back, or an agent that recovers later posts a
            // nudge the coding agent was told had not been sent, and the user
            // hears about the same thing twice.
            switch AtomicSpool.withdraw(file) {
            case .withdrawn:
                SelfTest.fail(NudgeNotification.explain(.agent(.notCollected), app: app))
                return 1
            case .stuck(let reason):
                SelfTest.fail(NudgeNotification.explain(.stuck(reason), app: app))
                return 1
            case .taken: break  // The agent took it after all.
            }
        }
        print(NudgeNotification.sent(tabKnown: tab != nil))
        return 0
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
