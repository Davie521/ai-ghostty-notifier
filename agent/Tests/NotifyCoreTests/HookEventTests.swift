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

    @Test func inputPromptIsTitledLikeACompletion() {
        // Only the subtitle, the body and the sound tell the two apart; the
        // title is the app name either way, with no emoji on it.
        let notice = NotificationPolicy.content(
            sampleEvent(kind: .notification), title: "", tabID: nil)
        #expect(notice.title == "Claude")
        #expect(notice.subtitle.hasPrefix("Input Required"))
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

@Suite("Background work keeps a Claude round open")
struct BackgroundWaitTests {
    private func payload(_ json: String) throws -> HookPayload {
        try JSONDecoder().decode(HookPayload.self, from: Data(json.utf8))
    }

    @Test func backgroundTasksAreReadLenientlyAndKeepOnlyIdentity() throws {
        let read = try payload(
            """
            {"session_id":"abc-123","hook_event_name":"Stop","prompt_id":"p-1","background_tasks":[
             {"id":"b1","type":"shell","status":"running","description":"lock","command":"x"},
             {"type":"subagent"},{"id":""},"junk",{"id":"b2"}]}
            """)
        #expect(read.promptID == "p-1")
        #expect(
            read.backgroundTasks == [
                BackgroundTask(id: "b1", type: "shell"), BackgroundTask(id: "b2"),
            ])
        for shape in ["null", "{}", "\"b1\"", "[[1]]"] {
            let odd = try payload(
                #"{"session_id":"abc-123","hook_event_name":"Stop","background_tasks":"#
                    + shape + "}")
            #expect(odd.backgroundTasks == nil || odd.backgroundTasks == [])
        }
        let wrong = try payload(
            #"{"session_id":"abc-123","hook_event_name":"UserPromptSubmit","source":7,"prompt_id":5,"prompt":"hi"}"#
        )
        #expect(wrong.promptSource == nil)
        #expect(wrong.promptID == nil)
        #expect(wrong.prompt == "hi")
    }

    @Test func newFieldsSurviveTheTripToTheResidentApp() throws {
        var event = sampleEvent()
        event.payload.backgroundTasks = [BackgroundTask(id: "b1", type: "shell")]
        event.awaitingBackground = true
        #expect(
            try RequestCodec.decode(RequestCodec.encode(.hookEvent(event))) == .hookEvent(event))
    }

    @Test(
        arguments: [
            ("system", nil, true), ("loop_wakeup", nil, true),
            ("user", "<task-notification>", false),
            ("sdk", nil, false), (nil, "  <task-notification>\n<task-id>b1</task-id>", true),
            (nil, "<task-notification> is the marker I am debugging", false),
            (nil, "hello", false), ("poll_event", nil, true), ("schedule_wakeup", nil, true),
            ("future", "hello", false),
            ("future", "<task-notification><task-id>b1</task-id>", true),
        ] as [(String?, String?, Bool)])
    func onlyPromptsNobodyTypedResumeTheRound(source: String?, prompt: String?, injected: Bool) {
        var event = sampleEvent(kind: .prompt)
        event.payload.promptSource = source
        event.payload.prompt = prompt
        #expect(event.isInjectedPrompt == injected)
        event.source = .codex
        #expect(!event.isInjectedPrompt)
    }

    private func capture(
        _ sandbox: HookSandbox, _ kind: HookKind, source: String? = nil, turn: String? = nil,
        prompt: String? = nil, owner: String = "process-1",
        tasks: [String]? = nil, typed: [BackgroundTask]? = nil, unidentified: Bool = false,
        settings: [String: String] = [:]
    ) async throws -> HookEvent {
        var event = sampleEvent(kind: kind, root: sandbox.root.path)
        event.settings = settings
        event.payload.promptSource = source
        event.payload.promptID = turn
        event.payload.prompt = prompt
        event.owner = owner
        event.payload.transcriptPath = sandbox.transcript
        event.payload.backgroundTasks =
            typed ?? tasks?.map { BackgroundTask(id: $0, type: "shell") }
        event.payload.backgroundUnidentified = unidentified ? true : nil
        let captured = try await DiskRoundJournal().capture(event)
        // Claude writes the transcript once a prompt is in.
        if kind == .prompt { try sandbox.write("transcript.jsonl", "{}\n") }
        return captured
    }

    /// A session this version sees from its first prompt.
    private func fresh() throws -> HookSandbox {
        let sandbox = try HookSandbox()
        _ = try sandbox.event()
        try FileManager.default.removeItem(at: sandbox.root.appendingPathComponent("abc-123.round"))
        return sandbox
    }

    /// A new session's first round, started at 1000.
    private func firstRound() async throws -> HookSandbox {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user")
        try sandbox.write("abc-123.start", "1000\n")
        return sandbox
    }

    private let report = "<task-notification>\n<task-id>lock</task-id>\n</task-notification>"

    private func started(_ sandbox: HookSandbox) -> String {
        DiskRoundJournal.read(sandbox.root.path + "/abc-123.start")
    }

    @Test func aRoundWaitingOnItsOwnTaskKeepsItsStartUntilTheTaskReportsBack() async throws {
        let sandbox = try await firstRound()
        let paused = try await capture(sandbox, .stop, tasks: ["lock"])
        #expect(paused.awaitingBackground == true)
        #expect(paused.startedAt == 1000)
        #expect(paused.payload.backgroundTasks == nil)
        let woken = try await capture(sandbox, .prompt, source: "system", prompt: report)
        #expect(woken.roundID != paused.roundID)
        #expect(started(sandbox) == "1000")
        let done = try await capture(sandbox, .stop, tasks: [])
        #expect(done.awaitingBackground == false)
        #expect(done.startedAt == 1000)
        // An empty record, not none: "nothing runs" is known, not unknown.
        #expect(FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.background"))
        let record = DiskRoundJournal.read(sandbox.root.path + "/abc-123.background")
        #expect(Snapshot(record) == Snapshot(owner: "process-1", tasks: []))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.paused"))
    }

    @Test func aWakeupAfterAFinishedRoundStartsItsOwnClock() async throws {
        let sandbox = try await firstRound()
        // The Stop is not yet drained by the app, so its start is still on disk.
        #expect(try await capture(sandbox, .stop, tasks: []).awaitingBackground == false)
        _ = try await capture(sandbox, .prompt, source: "loop_wakeup")
        #expect(started(sandbox).isEmpty)
    }

    @Test func workLeftRunningFromEarlierRoundsDoesNotHoldANewRound() async throws {
        let sandbox = try await firstRound()
        #expect(try await capture(sandbox, .stop, tasks: ["server"]).awaitingBackground == true)
        _ = try await capture(sandbox, .prompt, source: "user")
        #expect(started(sandbox).isEmpty)
        try sandbox.write("abc-123.start", "1500\n")
        let next = try await capture(sandbox, .stop, tasks: ["server"])
        #expect(next.awaitingBackground == false)
        #expect(next.startedAt == 1500)
        let more = try await capture(sandbox, .stop, tasks: ["server", "agent"])
        #expect(more.awaitingBackground == true)
    }

    @Test func onlyWorkThatWakesTheSessionHoldsTheRound() async throws {
        let sandbox = try await firstRound()
        let housekeeping =
            ["dream", "auto-mode scan", "memory save", "teammate", "MCP task", "code"]
            .map { BackgroundTask(id: $0, type: $0) } + [BackgroundTask(id: "untyped")]
        #expect(
            try await capture(sandbox, .stop, typed: housekeeping).awaitingBackground == false)
        // A later round: in a session's first one, every monitor counts as
        // already running.
        _ = try await capture(sandbox, .prompt, source: "user")
        for type in ["shell", "subagent", "monitor", "workflow"] {
            let waiting = try await capture(
                sandbox, .stop, typed: housekeeping + [BackgroundTask(id: type, type: type)])
            #expect(waiting.awaitingBackground == true)
        }
    }

    @Test func aNewTaskAfterManyEarlierOnesIsStillSeen() async throws {
        let sandbox = try await firstRound()
        let earlier = (0..<200).map { "old-\($0)" }
        _ = try await capture(sandbox, .stop, tasks: earlier)
        _ = try await capture(sandbox, .prompt, source: "user")
        #expect(try await capture(sandbox, .stop, tasks: earlier).awaitingBackground == false)
        #expect(
            try await capture(sandbox, .stop, tasks: earlier + ["new"]).awaitingBackground == true)
    }

    @Test func aMessageSentMidTurnStillWaitsForTheTurnsOwnTask() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        try sandbox.write("abc-123.start", "1000\n")
        // Claude fires the prompt hook for it with the running turn's id: the
        // message joins the turn, which keeps its clock.
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        #expect(started(sandbox) == "1000")
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        let stop = try await capture(sandbox, .stop, turn: "turn-a", tasks: ["lock"])
        #expect(stop.awaitingBackground == true)
        #expect(stop.startedAt == 1000)
    }

    @Test func workLeftByAnInterruptedTurnDoesNotHoldTheNextRound() async throws {
        let sandbox = try fresh()
        // Turn A starts a server and is interrupted: no Stop ever names it.
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        _ = try await capture(sandbox, .preTool, turn: "turn-b")
        let unknown = try await capture(sandbox, .stop, turn: "turn-b", tasks: ["server"])
        #expect(unknown.awaitingBackground == false)
        // Now the server is on record: the next round tells it apart again.
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-c")
        _ = try await capture(sandbox, .preTool, turn: "turn-c")
        let next = try await capture(sandbox, .stop, turn: "turn-c", tasks: ["server", "lock"])
        #expect(next.awaitingBackground == true)
    }

    @Test func twoTurnsWithoutAStopShowAnInterruptionEvenWithoutAnID() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        _ = try await capture(sandbox, .preTool, turn: "turn-b")
        #expect(try await capture(sandbox, .stop, tasks: ["server"]).awaitingBackground == false)
    }

    @Test func aWakeupAfterAnInterruptionLearnsWhatWasRunning() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        _ = try await capture(sandbox, .preTool, turn: "turn-b")
        _ = try await capture(sandbox, .stop, turn: "turn-b", tasks: ["server"])
        // Nothing was paused, so the wakeup starts a round of its own.
        _ = try await capture(sandbox, .prompt, source: "loop_wakeup", turn: "turn-w")
        _ = try await capture(sandbox, .preTool, turn: "turn-w")
        let wake = try await capture(sandbox, .stop, turn: "turn-w", tasks: ["server"])
        #expect(wake.awaitingBackground == false)
    }

    @Test func aSessionOlderThanThisVersionNotifiesUntilItsFirstStopIsSeen() async throws {
        let sandbox = try HookSandbox()
        _ = try sandbox.event()  // rounds on record, but no Stop seen by this version
        try sandbox.write("transcript.jsonl", "{}\n")
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        #expect(
            try await capture(sandbox, .stop, turn: "turn-a", tasks: ["server"]).awaitingBackground
                == false)
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        _ = try await capture(sandbox, .preTool, turn: "turn-b")
        let next = try await capture(sandbox, .stop, turn: "turn-b", tasks: ["server", "lock"])
        #expect(next.awaitingBackground == true)
    }

    @Test func aPauseThatCannotBeRecordedDoesNotHoldTheRound() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        let blocker = sandbox.root.appendingPathComponent("abc-123.paused")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try "keep".write(
            to: blocker.appendingPathComponent("inside"), atomically: true, encoding: .utf8)
        let stop = try await capture(sandbox, .stop, turn: "turn-a", tasks: ["lock"])
        #expect(stop.awaitingBackground == false)
        // Not a marker, and not ours to delete.
        _ = try await capture(sandbox, .prompt, source: "system")
        #expect(started(sandbox).isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: blocker.appendingPathComponent("inside").path))
    }

    @Test func aBaselineThatCannotBeRecordedDoesNotHoldTheRound() async throws {
        let sandbox = try fresh()
        try FileManager.default.createDirectory(
            at: sandbox.root.appendingPathComponent("abc-123.background-earlier"),
            withIntermediateDirectories: true)
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        let stop = try await capture(sandbox, .stop, turn: "turn-a", tasks: ["server"])
        #expect(stop.awaitingBackground == false)
    }

    @Test func anUpgradeMidTurnNotifiesThatTurn() async throws {
        let sandbox = try HookSandbox()
        _ = try sandbox.event()  // the older hook saw the prompt: only .round and .start
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        let stop = try await capture(sandbox, .stop, turn: "turn-a", tasks: ["server"])
        #expect(stop.awaitingBackground == false)
    }

    @Test func aStopWithTheSettingOffStillRecordsWhatRuns() async throws {
        let sandbox = try fresh()
        let off = ["GHOSTTY_NOTIFY_WAIT_BACKGROUND": "0"]
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a", settings: off)
        _ = try await capture(sandbox, .stop, turn: "turn-a", tasks: ["server"], settings: off)
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        let stop = try await capture(sandbox, .stop, turn: "turn-b", tasks: ["server"])
        #expect(stop.awaitingBackground == false)
    }

    @Test func aStopThatDoesNotSayWhatRunsLeavesTheNextRoundUnheld() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        _ = try await capture(sandbox, .stop, turn: "turn-a")
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        let stop = try await capture(sandbox, .stop, turn: "turn-b", tasks: ["server"])
        #expect(stop.awaitingBackground == false)
    }

    @Test func aStopWithTheSettingOffStillRetiresItsTurn() async throws {
        let sandbox = try fresh()
        let off = ["GHOSTTY_NOTIFY_WAIT_BACKGROUND": "0"]
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        _ = try await capture(sandbox, .stop, turn: "turn-a", tasks: ["x"], settings: off)
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        _ = try await capture(sandbox, .preTool, turn: "turn-b")
        let stop = try await capture(sandbox, .stop, turn: "turn-b", tasks: ["lock"])
        #expect(stop.awaitingBackground == true)
    }

    @Test func aResumedSessionOrOneOpenBeforeInstallIsNotHeldAtFirst() async throws {
        let sandbox = try fresh()
        try sandbox.write("transcript.jsonl", "{}\n")  // history, but none recorded here
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        let stop = try await capture(sandbox, .stop, turn: "turn-a", tasks: ["server"])
        #expect(stop.awaitingBackground == false)
    }

    @Test func turnsThatCannotBeRecordedHoldNothing() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        try FileManager.default.createDirectory(
            at: sandbox.root.appendingPathComponent("abc-123.turns"),
            withIntermediateDirectories: true)
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        let stop = try await capture(sandbox, .stop, turn: "turn-a", tasks: ["lock"])
        #expect(stop.awaitingBackground == false)
    }

    @Test func unreadableRecordsAreUnknownNotEmpty() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        try Data([0xFF, 0xFE]).write(
            to: sandbox.root.appendingPathComponent("abc-123.background-earlier"))
        #expect(
            try await capture(sandbox, .stop, turn: "turn-a", tasks: ["server"]).awaitingBackground
                == false)
        try Data([0xFF, 0xFE]).write(to: sandbox.root.appendingPathComponent("abc-123.background"))
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        #expect(
            try await capture(sandbox, .stop, turn: "turn-b", tasks: ["server"]).awaitingBackground
                == false)
    }

    @Test func anUnidentifiedTaskLeavesWhatRunsUnknown() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        let first = try await capture(sandbox, .stop, turn: "turn-a", tasks: [], unidentified: true)
        #expect(first.awaitingBackground == false)
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        let next = try await capture(sandbox, .stop, turn: "turn-b", tasks: ["server"])
        #expect(next.awaitingBackground == false)
    }

    @Test func onlyAnUnidentifiedEntryThatMayWakeTheSessionCounts() throws {
        func read(_ list: String) throws -> HookPayload {
            try JSONDecoder().decode(
                HookPayload.self,
                from: Data(
                    (#"{"session_id":"abc-123","hook_event_name":"Stop","background_tasks":"#
                        + list + "}").utf8))
        }
        #expect(try read(#"[{"type":"shell"}]"#).backgroundUnidentified == true)
        #expect(try read(#"[{"id":7}]"#).backgroundUnidentified == true)
        #expect(try read(#"["junk"]"#).backgroundUnidentified == true)
        #expect(
            try read(#"[{"type":"dream"},{"id":"b1","type":"shell"}]"#).backgroundUnidentified
                == nil)
        var event = sampleEvent()
        event.payload = try read(#"[{"type":"monitor"}]"#)
        let trip = try HookEvent.decode(JSONEncoder().encode(event))
        #expect(trip.payload.backgroundUnidentified == true)
    }

    @Test func aPauseMakesAnEarlierStopOfTheRoundStale() async throws {
        let sandbox = try await firstRound()
        let journal = DiskRoundJournal()
        // Another Stop hook made Claude go on after this Stop, not yet consumed.
        let earlier = try await capture(sandbox, .stop, tasks: [])
        let paused = try await capture(sandbox, .stop, tasks: ["lock"])
        #expect(paused.awaitingBackground == true)
        #expect(paused.roundID != earlier.roundID)
        #expect(!(await journal.isCurrent(earlier)))
        await journal.finish(earlier)
        #expect(started(sandbox) == "1000")
    }

    @Test func aScheduledJobIsNotTheReportAPausedRoundWaitsFor() async throws {
        let sandbox = try await firstRound()
        #expect(try await capture(sandbox, .stop, tasks: ["server"]).awaitingBackground == true)
        _ = try await capture(sandbox, .prompt, source: "schedule_wakeup", prompt: "nightly job")
        #expect(started(sandbox).isEmpty)
        #expect(try await capture(sandbox, .stop, tasks: ["server"]).awaitingBackground == false)
    }

    @Test func aPauseWithoutAnEarlierStopKeepsTheRoundsPrompt() async throws {
        let sandbox = try fresh()
        let prompt = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        let stop = try await capture(sandbox, .stop, turn: "turn-a", tasks: ["lock"])
        #expect(stop.awaitingBackground == true)
        #expect(stop.roundID == prompt.roundID)
        #expect(await DiskRoundJournal().isCurrent(prompt))
    }

    @Test func aTranscriptGoneLaterDoesNotEraseWhatRuns() async throws {
        let sandbox = try await firstRound()
        _ = try await capture(sandbox, .stop, tasks: ["server"])
        try FileManager.default.removeItem(atPath: sandbox.transcript)
        _ = try await capture(sandbox, .prompt, source: "user")
        #expect(try await capture(sandbox, .stop, tasks: ["server"]).awaitingBackground == false)
    }

    @Test func aToolUsedUnderNoKnownTurnHoldsNothing() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        _ = try await capture(sandbox, .preTool)
        #expect(
            try await capture(sandbox, .stop, turn: "turn-a", tasks: ["lock"]).awaitingBackground
                == false)
    }

    @Test func anInterruptionCountsForTheRestOfTheRound() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        _ = try await capture(sandbox, .preTool, turn: "turn-b")
        _ = try await capture(sandbox, .stop, turn: "turn-b", tasks: [])
        // Another Stop hook made Claude go on, and A's server shows up now.
        let again = try await capture(sandbox, .stop, turn: "turn-b", tasks: ["server"])
        #expect(again.awaitingBackground == false)
    }

    @Test func aTaskSeenWithoutItsKindIsNotNewWhenTheKindShows() async throws {
        let sandbox = try await firstRound()
        _ = try await capture(sandbox, .stop, typed: [BackgroundTask(id: "server")])
        _ = try await capture(sandbox, .prompt, source: "user")
        #expect(try await capture(sandbox, .stop, tasks: ["server"]).awaitingBackground == false)
    }

    @Test func aMessageRightAfterTheReportStillJoinsTheResumedRound() async throws {
        let sandbox = try await firstRound()
        #expect(try await capture(sandbox, .stop, tasks: ["lock"]).awaitingBackground == true)
        _ = try await capture(sandbox, .prompt, source: "system", turn: "turn-w", prompt: report)
        // Sent while Claude reads the report, before it uses any tool.
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-w")
        #expect(started(sandbox) == "1000")
        let done = try await capture(sandbox, .stop, turn: "turn-w", tasks: [])
        #expect(done.startedAt == 1000)
    }

    @Test func shellsAnEarlierSubagentMayHaveStartedDoNotHoldTheRound() async throws {
        let sandbox = try await firstRound()
        let agent = BackgroundTask(id: "agent", type: "subagent")
        _ = try await capture(sandbox, .stop, typed: [agent])
        _ = try await capture(sandbox, .prompt, source: "user")
        let shell = BackgroundTask(id: "sh", type: "shell")
        #expect(
            try await capture(sandbox, .stop, typed: [agent, shell]).awaitingBackground == false)
        let another = BackgroundTask(id: "agent-2", type: "subagent")
        #expect(
            try await capture(sandbox, .stop, typed: [agent, shell, another]).awaitingBackground
                == true)
    }

    @Test func aResumedProcessDoesNotTrustTheLastOnesRecord() async throws {
        let sandbox = try await firstRound()
        _ = try await capture(sandbox, .stop, tasks: [])
        _ = try await capture(sandbox, .prompt, source: "user", owner: "process-2")
        #expect(
            try await capture(sandbox, .stop, owner: "process-2", tasks: ["lock"])
                .awaitingBackground == false)
        // Once the new process has stopped, its own record counts.
        _ = try await capture(sandbox, .prompt, source: "user", owner: "process-2")
        #expect(
            try await capture(sandbox, .stop, owner: "process-2", tasks: ["lock", "new"])
                .awaitingBackground == true)
    }

    @Test func aFirstRoundCountsEveryMonitorAsAlreadyRunning() async throws {
        let sandbox = try await firstRound()
        let monitor = BackgroundTask(id: "plugin-watch", type: "monitor")
        #expect(try await capture(sandbox, .stop, typed: [monitor]).awaitingBackground == false)
        #expect(
            try await capture(
                sandbox, .stop, typed: [monitor, BackgroundTask(id: "s", type: "shell")]
            )
            .awaitingBackground == true)
    }

    @Test func aTranscriptThatCannotBeLookedAtIsNotAbsent() async throws {
        let sandbox = try fresh()
        let locked = sandbox.root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }
        #expect(!DiskRoundJournal.confirmedAbsent(locked.appendingPathComponent("t.jsonl").path))
        #expect(DiskRoundJournal.confirmedAbsent(sandbox.root.appendingPathComponent("no").path))
    }

    @Test func anInterruptionSurvivesAStopThatSaysNothing() async throws {
        let sandbox = try fresh()
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        _ = try await capture(sandbox, .preTool, turn: "turn-a")
        _ = try await capture(sandbox, .prompt, source: "user", turn: "turn-b")
        _ = try await capture(sandbox, .preTool, turn: "turn-b")
        _ = try await capture(sandbox, .stop, turn: "turn-b", tasks: [], unidentified: true)
        let again = try await capture(sandbox, .stop, turn: "turn-b", tasks: ["server"])
        #expect(again.awaitingBackground == false)
    }

    @Test func twoHeldStopsKeepTheRoundsPrompt() async throws {
        let sandbox = try fresh()
        let prompt = try await capture(sandbox, .prompt, source: "user", turn: "turn-a")
        #expect(
            try await capture(sandbox, .stop, turn: "turn-a", tasks: ["a"]).awaitingBackground
                == true)
        let second = try await capture(sandbox, .stop, turn: "turn-a", tasks: ["a", "b"])
        #expect(second.awaitingBackground == true)
        #expect(await DiskRoundJournal().isCurrent(prompt))
    }

    @Test func anOlderClaudeOrTheSettingOffKeepsTheOldBehavior() async throws {
        let sandbox = try HookSandbox()
        _ = try sandbox.event()
        #expect(try await capture(sandbox, .stop).awaitingBackground == nil)
        let off = ["GHOSTTY_NOTIFY_WAIT_BACKGROUND": "off"]
        #expect(
            try await capture(sandbox, .stop, tasks: ["lock"], settings: off).awaitingBackground
                == nil)
        _ = try await capture(sandbox, .prompt, source: "system", settings: off)
        #expect(started(sandbox).isEmpty)
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
    var transcript: String { root.appendingPathComponent("transcript.jsonl").path }
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
