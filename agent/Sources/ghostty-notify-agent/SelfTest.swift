import AppKit
import Foundation
import NotifyCore

/// `ghostty-notify-agent --test`: one real notification through the resident
/// agent, so an install can be checked on demand rather than by waiting out a
/// three-minute task. The content and the messages live in NotifyCore's
/// `TestNotification`; this is the part that needs a terminal and a process.
@MainActor
enum SelfTest {
    static func run(paths: AgentPaths) async -> Int32 {
        let transport = HookTransport(paths: paths)
        let app = Bundle.main.bundlePath
        if let problem = TestNotification.problem(
            running: transport.runningPID != nil,
            readiness: DiskRoundJournal.read(paths.readyFile))
        {
            fail(TestNotification.explain(problem, app: app))
            return 1
        }
        let (tab, target) = await frontTab()
        let file: String
        do {
            file = try transport.queue(.notify(TestNotification.request(tabID: tab)))
        } catch {
            fail("Could not queue the test notification: \(error)")
            return 1
        }
        // Delivery itself is the agent's, and only the screen can confirm it.
        // What can be checked here is that the agent took the request.
        var waited = 0
        while FileManager.default.fileExists(atPath: file), waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        if FileManager.default.fileExists(atPath: file) {
            fail(TestNotification.explain(.notCollected, app: app))
            return 1
        }
        print(TestNotification.sent(target))
        return 0
    }

    /// The tab in front when the test was run: the one typed in, by hand or
    /// from an installer. A coding agent's shell has no terminal of its own to
    /// mark, and its user is most likely looking at its tab. No tab when
    /// another app is in front, or when Ghostty does not answer in time.
    private static func frontTab() async -> (String?, TestNotification.Target) {
        AppleEventHost.prepare()
        let automation = MacTerminalAutomation()
        switch await automation.isFrontmost() {
        case false?: return (nil, .ghosttyNotInFront)
        case nil: return (nil, .tabUnknown)
        case true?:
            let tab = try? await QueryDeadline.run(seconds: 4) {
                await automation.selectedTabID()
            }
            if let tab { return (tab, .tab) }
            return (nil, .tabUnknown)
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data(("ghostty-notify: " + message + "\n").utf8))
    }
}
