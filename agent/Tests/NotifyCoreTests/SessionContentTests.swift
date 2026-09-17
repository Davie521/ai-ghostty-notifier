import Foundation
import Testing

@testable import NotifyCore

@Suite("Native session titles and continuation")
struct SessionContentTests {
    @Test func customTitleWinsOverNewerAITitleAndMessageLookalikes() async throws {
        let sandbox = try HookSandbox()
        let reader = DiskSessionContent()
        var event = try sandbox.event()
        event.payload.transcriptPath = sandbox.root.appendingPathComponent("transcript.jsonl").path
        try sandbox.write(
            "transcript.jsonl",
            #"{"type":"custom-title","customTitle":"old"}"# + "\n"
                + #"{"type":"assistant","message":"custom-title","customTitle":"fake"}"# + "\n"
                + "not json\n"
                + #"{"type" : "custom-title", "customTitle":"中文\n第二行"}"# + "\n"
                + #"{"type":"ai-title","aiTitle":"newer but lower priority"}"#)
        #expect(await reader.title(for: event) == "中文 第二行")
        event.payload.sessionTitle = "stdin\u{1B}title"
        #expect(await reader.title(for: event) == "stdintitle")
    }

    @Test func missingTranscriptAndBlankLastCustomTitleFallBack() async throws {
        let sandbox = try HookSandbox()
        let reader = DiskSessionContent()
        var event = try sandbox.event()
        event.payload.transcriptPath = sandbox.root.appendingPathComponent("transcript.jsonl").path
        #expect(await reader.title(for: event) == "")
        try sandbox.write(
            "transcript.jsonl",
            #"{"type":"ai-title","aiTitle":"ai name"}"# + "\n"
                + #"{"type":"custom-title","customTitle":""}"# + "\n")
        #expect(await reader.title(for: event) == "ai name")
    }

    @Test func oversizedNonTitleLineDoesNotHideFollowingTitle() async throws {
        let sandbox = try HookSandbox()
        let reader = DiskSessionContent()
        var event = try sandbox.event()
        event.payload.transcriptPath = sandbox.root.appendingPathComponent("transcript.jsonl").path
        try sandbox.write(
            "transcript.jsonl",
            String(repeating: "x", count: 2_000_000) + "\n"
                + #"{"type":"ai-title","aiTitle":"after big line"}"# + "\n")
        #expect(await reader.title(for: event) == "after big line")
    }

    @Test func continuationRequiresDifferentRecentTurn() async throws {
        let sandbox = try HookSandbox()
        let reader = DiskSessionContent()
        var event = try sandbox.event(source: .codex)
        event.payload.turnID = "current"
        event.payload.transcriptPath = sandbox.root.appendingPathComponent("rollout.jsonl").path
        func record(_ turn: String, _ started: Double) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "event_msg",
                "payload": [
                    "type": "task_started", "turn_id": turn, "started_at": started,
                ],
            ])
            try data.write(to: sandbox.root.appendingPathComponent("rollout.jsonl"))
        }
        try record("next", 2000)
        #expect(await reader.isContinuing(event))
        try record("current", 2000)
        #expect(!(await reader.isContinuing(event)))
        try record("old", 1000)
        #expect(!(await reader.isContinuing(event)))
    }

    @Test func utf8SplitAtTailBoundaryDoesNotHideContinuation() async throws {
        let sandbox = try HookSandbox()
        let reader = DiskSessionContent()
        var event = try sandbox.event(source: .codex)
        event.payload.turnID = "current"
        event.payload.transcriptPath = sandbox.root.appendingPathComponent("rollout.jsonl").path
        let tail =
            "\n"
            + #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"next","started_at":2000}}"#
            + "\n"
        try sandbox.write("rollout.jsonl", String(repeating: "中", count: 100_000) + tail)
        #expect(await reader.isContinuing(event))
    }

    @Test func codexDatabaseRespectsConfiguredDirectoryAndSchemaVersion() async throws {
        let sandbox = try HookSandbox()
        let reader = DiskSessionContent()
        var event = try sandbox.event(source: .codex)
        event.codexHome = sandbox.root.path
        let databaseRoot = sandbox.root.appendingPathComponent("databases")
        try FileManager.default.createDirectory(at: databaseRoot, withIntermediateDirectories: true)
        try sandbox.write(
            "config.toml",
            "sqlite_home = \"\(databaseRoot.path)\"\n[other]\nsqlite_home = \"/wrong\"\n")
        for (version, title) in [(1, "old"), (9, "database name")] {
            _ = await ChildCommand.output(
                executable: "/usr/bin/sqlite3",
                arguments: [
                    databaseRoot.appendingPathComponent("state_\(version).sqlite").path,
                    "CREATE TABLE threads(id TEXT, name TEXT); INSERT INTO threads VALUES ('abc-123', '\(title)');",
                ])
        }
        try sandbox.write("abc-123.title", "first prompt\n")
        #expect(await reader.title(for: event) == "database name")
        // An explicitly empty config value still falls back to the environment;
        // a nested setting must not override the top-level storage choice.
        try sandbox.write("config.toml", "sqlite_home = \"\"\n[other]\nsqlite_home = \"/wrong\"\n")
        event.codexSQLiteHome = databaseRoot.path
        #expect(await reader.title(for: event) == "database name")
    }
}
