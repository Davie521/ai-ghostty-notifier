import Foundation
import Testing

@testable import NotifyCore

func sampleEvent(
    kind: HookKind = .stop, source: HookSource = .claude,
    root: String = "/tmp/hooks-test"
) -> HookEvent {
    HookEvent(
        source: source, roundID: "2000-123-1", occurredAt: 2000, startedAt: 1000,
        sessionDirectory: root, rateDirectory: root + "/rates",
        payload: HookPayload(sessionID: "abc-123", kind: kind, cwd: "/work/项目"))
}

@Suite("Native hook protocol and policy")
struct HookEventTests {
    @Test func eventRoundTripAndLegacyCoexist() throws {
        var event = sampleEvent()
        event.payload.sessionTitle = "标题\t\\name\n"
        event.settings = [
            "GHOSTTY_NOTIFY_MIN_ELAPSED": "007", "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "off",
        ]
        #expect(
            try RequestCodec.decode(RequestCodec.encode(.hookEvent(event))) == .hookEvent(event))
        let old = AgentRequest.notify(NotifyRequest(sessionID: "abc-123", title: "old"))
        #expect(try RequestCodec.decode(RequestCodec.encode(old)) == old)
    }

    @Test func unsupportedOrUnsafeEventsAreRejected() throws {
        var event = sampleEvent()
        event.version = 2
        #expect(throws: (any Error).self) {
            try RequestCodec.decode(RequestCodec.encode(.hookEvent(event)))
        }
        event.version = 1
        event.roundID = "../escape"
        #expect(throws: (any Error).self) {
            try RequestCodec.decode(RequestCodec.encode(.hookEvent(event)))
        }
        event.roundID = "valid"
        event.payload.agentID = "sub-agent"
        #expect(throws: (any Error).self) {
            try RequestCodec.decode(RequestCodec.encode(.hookEvent(event)))
        }
    }

    @Test(arguments: [
        (179.0, false, false), (180.0, true, false), (599.0, true, false), (600.0, true, true),
    ])
    func elapsedBoundaries(_ elapsed: Double, _ qualified: Bool, _ audible: Bool) {
        var event = sampleEvent()
        event.occurredAt = event.startedAt + elapsed
        #expect(NotificationPolicy.qualifies(event) == qualified)
        #expect((NotificationPolicy.content(event, title: "", tabID: nil).sound != nil) == audible)
    }

    @Test func absentAndFutureStartsStaySilent() {
        var event = sampleEvent()
        event.startedAt = 0
        #expect(!NotificationPolicy.qualifies(event))
        event.startedAt = event.occurredAt + 1
        #expect(!NotificationPolicy.qualifies(event))
    }

    @Test func inputPromptBypassesElapsedButIsOptIn() {
        var event = sampleEvent(kind: .notification)
        event.startedAt = 0
        #expect(!NotificationPolicy.qualifies(event))
        event.settings["GHOSTTY_NOTIFY_ON_PROMPT"] = "1"
        #expect(NotificationPolicy.qualifies(event))
        #expect(NotificationPolicy.content(event, title: "", tabID: nil).sound == "Ping")
    }

    @Test func settingsRemainPerRequestAndPreserveDefaults() {
        let a = HookOptions([
            "GHOSTTY_NOTIFY_MIN_ELAPSED": "3m", "GHOSTTY_NOTIFY_TIMEOUT": "000",
            "GHOSTTY_NOTIFY_SOUND_ELAPSED": "0007", "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "NO",
        ])
        #expect(a.minimum == 180)
        #expect(a.soundAfter == 7)
        #expect(a.timeout == nil)
        #expect(!a.clearOnFocus)
        #expect(HookOptions([:]).clearOnFocus)
    }

    @Test func emptyAppNameKeepsTheClaudeDefault() {
        var event = sampleEvent()
        event.settings["GHOSTTY_NOTIFY_APP_NAME"] = ""
        #expect(NotificationPolicy.content(event, title: "", tabID: nil).title == "Claude")
    }

    @Test(arguments: [
        ("", true), ("auto", true), ("agent", true),
        ("alerter", false), ("terminal-notifier", false), ("unknown", false),
    ])
    func backendSelectionKeepsShellDefaultSemantics(_ setting: String, _ resident: Bool) {
        let options = HookOptions(["GHOSTTY_NOTIFY_BACKEND": setting])
        #expect(options.backend == (setting.isEmpty ? "auto" : setting))
        #expect(options.prefersResident == resident)
    }

    @Test func notificationUsesCapturedTimeAndSource() {
        let event = sampleEvent(source: .codex)
        let notice = NotificationPolicy.content(event, title: "中文", tabID: "tab-1")
        #expect(notice.title == "Codex")
        #expect(notice.body == "Finished after 16m 40s")
        #expect(notice.subtitle == "中文 — 项目")
        #expect(notice.stateKey != sampleEvent().key)
        #expect(notice.sessionID == sampleEvent().sessionID)
    }

    @Test func sourceScopedRequestsRemainValidOnTheWire() throws {
        let event = sampleEvent(source: .codex)
        let requests: [AgentRequest] = [
            .notify(NotificationPolicy.content(event, title: "Codex", tabID: nil)),
            .dismiss(sessionID: event.sessionID, source: .codex),
            .anchor(sessionID: event.sessionID, tabID: "tab-1", source: .codex),
        ]
        for request in requests {
            #expect(try RequestCodec.decode(RequestCodec.encode(request)) == request)
        }
    }

    @Test func latePromptCannotDismissItsOwnCompletionAfterRestart() throws {
        var state = SessionState()
        let id = state.newNotification(sessionID: "abc-123", now: 2000, roundID: "round-b")
        state = StateCodec.decode(try StateCodec.encode(state))
        #expect(
            state.takePreviousRoundNotifications(sessionID: "abc-123", roundID: "round-b").isEmpty)
        #expect(
            state.takePreviousRoundNotifications(sessionID: "abc-123", roundID: "round-c") == [id])
    }
}

final class HookSandbox: @unchecked Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ghostty-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ name: String, _ value: String) throws {
        try value.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func event(kind: HookKind = .stop, source: HookSource = .claude) throws -> HookEvent {
        let event = sampleEvent(kind: kind, source: source, root: root.path)
        try write("abc-123.round", event.roundID + "\n")
        try write("abc-123.start", "1000\n")
        return event
    }
}

@Suite("Round and rate journal")
struct RoundJournalTests {
    @Test func oldCompletionCannotRemoveANewerStart() async throws {
        let sandbox = try HookSandbox()
        let journal = DiskRoundJournal()
        let event = try sandbox.event()
        try sandbox.write("abc-123.round", "new-round\n")
        try sandbox.write("abc-123.start", "2001\n")
        await journal.finish(event)
        #expect(DiskRoundJournal.read(sandbox.root.path + "/abc-123.start") == "2001")
        #expect(!(await journal.isCurrent(event)))
    }

    @Test func completionRemovesOnlyItsStart() async throws {
        let sandbox = try HookSandbox()
        let journal = DiskRoundJournal()
        let event = try sandbox.event()
        await journal.finish(event)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.start"))
        #expect(await journal.isCurrent(event))
    }

    @Test func restartAndLegacyStampsShareTheSameWindow() async throws {
        let sandbox = try HookSandbox()
        let event = try sandbox.event()
        try FileManager.default.createDirectory(
            atPath: event.rateDirectory, withIntermediateDirectories: true)
        // Exactly the legacy file format; neither a private in-memory map nor
        // another instance of the agent may bypass this stamp.
        try "1995\n".write(
            toFile: DiskRoundJournal.rateFile(event), atomically: true, encoding: .utf8)
        #expect(!(await DiskRoundJournal().claimRate(event, now: 2000)))
        #expect(await DiskRoundJournal().claimRate(event, now: 2005))
        #expect(!(await DiskRoundJournal().claimRate(event, now: 2006)))
    }

    @Test func parallelClaimantsHaveOneWinner() async throws {
        let sandbox = try HookSandbox()
        let event = try sandbox.event()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask { await DiskRoundJournal().claimRate(event, now: 2000) }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        #expect(winners == 1)
    }

    @Test func corruptRateStampSuppressesOnceAndRecovers() async throws {
        let sandbox = try HookSandbox()
        let journal = DiskRoundJournal()
        let event = try sandbox.event()
        try FileManager.default.createDirectory(
            atPath: event.rateDirectory, withIntermediateDirectories: true)
        try "broken".write(
            toFile: DiskRoundJournal.rateFile(event), atomically: true, encoding: .utf8)
        #expect(!(await journal.claimRate(event, now: 2000)))
        #expect(await journal.claimRate(event, now: 2000))
    }

    @Test func codexOwnerChangeInvalidatesBindingAndStoresFirstPrompt() async throws {
        let sandbox = try HookSandbox()
        let journal = DiskRoundJournal()
        var event = try sandbox.event(kind: .prompt, source: .codex)
        event.owner = "2:tty2:start"
        event.payload.prompt = "  中文\n第二行 "
        try sandbox.write("abc-123.codex-owner", "1:tty1:old\n")
        try sandbox.write("abc-123.json", "{\"tab_id\":\"old-tab\"}")
        await journal.prepare(event)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.json"))
        #expect(DiskRoundJournal.read(sandbox.root.path + "/abc-123.title") == "中文 第二行")
        event.payload.prompt = "later"
        await journal.prepare(event)
        #expect(DiskRoundJournal.read(sandbox.root.path + "/abc-123.title") == "中文 第二行")
    }
}
