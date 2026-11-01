import Foundation
import Testing

@testable import NotifyCore

private struct Processes: ProcessInspecting {
    var table: [Int32: HostProcess]
    var argv: [Int32: [String]] = [:]
    func process(_ pid: Int32) -> HostProcess? { table[pid] }
    func arguments(_ pid: Int32) -> [String] { argv[pid] ?? [] }
}

private func process(_ pid: Int32, _ parent: Int32, _ name: String, _ executable: String)
    -> HostProcess
{
    HostProcess(pid: pid, parent: parent, name: name, executable: executable, tty: nil, birth: "1")
}

/// Where a sandboxed `--nudge` leaves its notification, and which CLI asked.
@Suite struct NudgeSpoolTests {
    @Test func theNudgeSpoolIsTheUsersOwnAndKeyedByHome() throws {
        let one = try #require(try AgentPaths(env: ["HOME": "/Users/someone"]).nudgeSpool)
        let other = try #require(try AgentPaths(env: ["HOME": "/tmp/sandbox"]).nudgeSpool)
        let temporary = try #require(AgentPaths.userTemporaryDirectory())
        #expect(one.hasPrefix(temporary))
        #expect(one.hasSuffix("/nudges"))
        #expect(one != other)
        let again = try AgentPaths(env: ["HOME": "/Users/someone"]).nudgeSpool
        #expect(one == again)
        #expect(!one.hasPrefix("/Users/someone"))
    }

    /// The agent and `--nudge` of different releases must find the same spool.
    @Test func theKeyIsStableAcrossReleases() {
        #expect(AgentPaths.digest("/Users/someone") == "1363963a0afd3685")
        #expect(AgentPaths.digest("") == "cbf29ce484222325")
    }

    /// A sandbox may refuse the question to macOS; TMPDIR names the same
    /// directory for the user's own processes.
    @Test func withoutAnAnswerFromMacOSTMPDIRIsUsed() {
        #expect(AgentPaths.temporaryDirectory(named: "/var/f/T/", orTMPDIR: "/x/") == "/var/f/T/")
        #expect(AgentPaths.temporaryDirectory(named: nil, orTMPDIR: "/var/f/T") == "/var/f/T/")
        #expect(AgentPaths.temporaryDirectory(named: "", orTMPDIR: "/var/f/T/") == "/var/f/T/")
        #expect(AgentPaths.temporaryDirectory(named: nil, orTMPDIR: "relative") == nil)
        #expect(AgentPaths.temporaryDirectory(named: "/", orTMPDIR: nil) == nil)
        #expect(AgentPaths.temporaryDirectory(named: nil, orTMPDIR: nil) == nil)
    }

    @Test func theAgentPublishesItBesideItsOtherState() throws {
        #expect(
            try AgentPaths(env: ["HOME": "/h"]).nudgeSpoolFile
                == "/h/.claude/notifications/ghostty-agent/nudge-spool")
    }

    @Test func onlyAnAbsoluteOverrideMovesIt() throws {
        let moved = try AgentPaths(env: ["HOME": "/h", "GHOSTTY_NOTIFY_NUDGE_SPOOL": "/s/n"])
        #expect(moved.nudgeSpool == "/s/n")
        let usual = try AgentPaths(env: ["HOME": "/h"]).nudgeSpool
        for ignored in ["relative/n", "/", ""] {
            let paths = try AgentPaths(env: ["HOME": "/h", "GHOSTTY_NOTIFY_NUDGE_SPOOL": ignored])
            #expect(paths.nudgeSpool == usual)
        }
    }

    @Test func theNearestCLIAboveTheCommandIsTheOneAsking() {
        // Codex started from Claude Code's Bash tool runs the command.
        let codexInClaude = Processes(table: [
            10: process(10, 20, "ghostty-notify", "/app/ghostty-notify-agent"),
            20: process(20, 30, "zsh", "/bin/zsh"),
            30: process(30, 40, "codex", "/vendor/bin/codex"),
            40: process(40, 50, "zsh", "/bin/zsh"),
            50: process(50, 1, "claude", "/versions/2.1.316"),
        ])
        #expect(
            HookProcessContext.nearest(
                among: [.claude, .codex], startingAt: 10, inspector: codexInClaude) == .codex)
        // Claude Code itself.
        let claude = Processes(
            table: [
                10: process(10, 20, "ghostty-notify", "/app/ghostty-notify-agent"),
                20: process(20, 30, "zsh", "/bin/zsh"),
                30: process(30, 1, "2.1.316", "/versions/2.1.316"),
            ], argv: [30: ["claude"]])
        #expect(
            HookProcessContext.nearest(among: [.claude, .codex], startingAt: 10, inspector: claude)
                == .claude)
        let neither = Processes(table: [10: process(10, 1, "zsh", "/bin/zsh")])
        #expect(
            HookProcessContext.nearest(
                among: [.claude, .codex], startingAt: 10, inspector: neither) == nil)
    }
}
