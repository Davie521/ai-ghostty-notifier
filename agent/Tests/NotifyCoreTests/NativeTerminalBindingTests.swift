import Foundation
import Testing

@testable import NotifyCore

private struct InstantBindingClock: HookClockProviding {
    func now() -> Double { 2000 }
    func sleep(seconds: Double) async throws { try Task.checkCancellation() }
}

private final class TerminalFixture: TerminalAutomationProviding, TerminalTitleWriting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var titles: [TerminalTab] = [TerminalTab(id: "tab-1", title: "中文\t完整\n标题")]
    private var writes: [String] = []
    private var routedWrites: [String] = []
    private var terminals: [String: Int] = [:]
    private var queries = 0
    private var unavailable = false
    private var pid: pid_t = 123
    private var misses = 0
    private var queryFailures: [Int: Int] = [:]
    private var hungQueries: Set<Int> = []
    private var partialWrite = false
    private var restorationFailure = false
    private var overwrittenMarkers = 0
    var recorded: [String] { lock.withLock { writes } }
    /// "terminal <- title", for tests where it matters which terminal was written.
    var routed: [String] { lock.withLock { routedWrites } }
    /// Titles go to the first tab unless a terminal is attached to another.
    func attach(_ tty: String, toTab index: Int) { lock.withLock { terminals[tty] = index } }
    var queryCount: Int { lock.withLock { queries } }
    var visible: [TerminalTab] { lock.withLock { titles } }
    func failSnapshots() { lock.withLock { unavailable = true } }
    func failQueries(_ numbers: [Int], code: Int = -1712) {
        lock.withLock { for number in numbers { queryFailures[number] = code } }
    }
    /// These queries never answer, like an NSAppleScript send whose reply is
    /// never serviced. Cancellable only so an abandoned one does not outlive
    /// its test; nothing under test may depend on that.
    func hangQueries(_ numbers: [Int]) { lock.withLock { hungQueries.formUnion(numbers) } }
    func setTabs(_ value: [TerminalTab]) { lock.withLock { titles = value } }
    func failPartialMarkerWrite() { lock.withLock { partialWrite = true } }
    func failRestoration() { lock.withLock { restorationFailure = true } }
    func overwriteMarkers(_ count: Int) { lock.withLock { overwrittenMarkers = count } }
    func restart() { lock.withLock { pid += 1 } }
    func missMarkers(_ count: Int) { lock.withLock { misses = count } }
    func processID() async -> pid_t? { lock.withLock { pid } }
    func tabs() async throws -> [TerminalTab] {
        let (number, hangs) = lock.withLock { () -> (Int, Bool) in
            queries += 1
            return (queries, hungQueries.contains(queries))
        }
        if hangs { try await Task.sleep(for: .seconds(3600)) }
        return try lock.withLock {
            if let code = queryFailures[number] {
                throw NSError(domain: "GhosttyAppleEvents", code: code)
            }
            if unavailable { throw CocoaError(.fileReadNoPermission) }
            if misses > 0, titles.first?.title.contains("TAB_MARKER") == true {
                misses -= 1
                return []
            }
            return titles
        }
    }
    func write(title: String, tty: String) throws {
        try lock.withLock {
            writes.append(title)
            routedWrites.append(tty + " <- " + title)
            guard !titles.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            let tab = terminals[tty] ?? 0
            if title.contains("TAB_MARKER"), partialWrite {
                partialWrite = false
                titles[tab].title = String(title.prefix(12))
                throw CocoaError(.fileWriteUnknown)
            }
            if !title.contains("TAB_MARKER"), restorationFailure {
                throw CocoaError(.fileWriteUnknown)
            }
            if title.contains("TAB_MARKER"), overwrittenMarkers > 0 {
                overwrittenMarkers -= 1
                titles[tab].title = "new TUI title"
                return
            }
            titles[tab].title = title
        }
    }
    func focus(tabID: String?) async {}
    func isFrontmost() async -> Bool? { false }
    func selectedTabID() async -> String? { nil }
}

private final class SteppedBindingClock: HookClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 2000
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
    func sleep(seconds: Double) async throws { try Task.checkCancellation() }
}

private actor PausedBindingClock: HookClockProviding {
    private var continuation: CheckedContinuation<Void, Never>?
    nonisolated func now() -> Double { 2000 }
    func sleep(seconds: Double) async throws {
        if seconds > 0 { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
    }
    func waitForMarker() async throws {
        for _ in 0..<1000 {
            if continuation != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CocoaError(.executableRuntimeMismatch)
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Native terminal binding, without shell helpers")
struct NativeTerminalBindingTests {
    @Test func restoresStructuredTitleAndCachesWithoutAppleEvents() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event(source: .codex)
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == "tab-1")
        #expect(terminal.recorded == ["__codex_TAB_MARKER_abc-123__", "中文\t完整\n标题"])
        let queries = terminal.queryCount
        #expect(await binding.resolve(event) == "tab-1")
        #expect(terminal.queryCount == queries)
        #expect(DiskRoundJournal.read(sandbox.root.path + "/abc-123.json").contains("123"))
    }

    @Test func permissionFailureNeverWritesAMarkerAndBacksOff() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event(source: .codex)
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.failSnapshots()
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.recorded.isEmpty)
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.queryCount == 1)
    }

    @Test func ghosttyRestartInvalidatesTheCachedProcessIdentity() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event(source: .codex)
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == "tab-1")
        terminal.restart()
        #expect(await binding.existing(event) == nil)
        #expect(await binding.resolve(event) == "tab-1")
        #expect(terminal.recorded.count == 4)
    }

    @Test func cancellationRestoresTitleButCannotPublishIntoNewRound() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event(source: .codex)
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        let clock = PausedBindingClock()
        let binding = NativeTerminalBinding(automation: terminal, writer: terminal, clock: clock)
        let work = Task { await binding.resolve(event) }
        try await clock.waitForMarker()
        try sandbox.write("abc-123.round", "next-round\n")
        work.cancel()
        await clock.resume()
        #expect(await work.value == nil)
        #expect(terminal.recorded.last == "中文\t完整\n标题")
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.json"))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.lock"))
    }

    @Test func anotherProcessHoldingTheMarkerLeasePreventsAnyOSC() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event(source: .codex)
        event.tty = "/dev/fixture"
        let lease = try #require(DirectoryLease.acquire(sandbox.root.path + "/abc-123.lock"))
        defer { lease.release() }
        let terminal = TerminalFixture()
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.recorded.isEmpty)
    }

    @Test func outputCannotInjectEscapeSequencesOrWriteRegularFiles() throws {
        let packet = MacTerminalTitleWriter.packet("title\u{1b}]0;evil\u{7}\n")
        #expect(String(decoding: packet, as: UTF8.self) == "\u{1b}]2;title]0;evil\u{1b}\\")
        let sandbox = try HookSandbox()
        try sandbox.write("not-a-tty", "untouched")
        #expect(throws: (any Error).self) {
            try MacTerminalTitleWriter().write(title: "bad", tty: sandbox.root.path + "/not-a-tty")
        }
        #expect(DiskRoundJournal.read(sandbox.root.path + "/not-a-tty") == "untouched")
    }

    @Test func transientSnapshotFailureDoesNotCreateDailyBackoff() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.failQueries([1])
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.recorded.isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: sandbox.root.path + "/applescript-unavailable"))
        #expect(await binding.resolve(event) == "tab-1")
        #expect(terminal.recorded.last == "中文\t完整\n标题")
    }

    @Test func expiredPermissionBackoffCanBindAgain() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        try sandbox.write("applescript-unavailable", "unavailable")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2000 - 86400)],
            ofItemAtPath: sandbox.root.path + "/applescript-unavailable")
        let terminal = TerminalFixture()
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == "tab-1")
        #expect(
            !FileManager.default.fileExists(atPath: sandbox.root.path + "/applescript-unavailable"))
    }

    @Test func emptySnapshotCannotWriteAnyMarker() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.setTabs([])
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.recorded.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.json"))
    }

    @Test func threeOverwrittenMarkersCreateNegativeCacheUntilGhosttyRestarts() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.overwriteMarkers(3)
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        for attempt in 1...3 {
            #expect(await binding.resolve(event) == nil)
            #expect(terminal.recorded.count == attempt)
            #expect(terminal.visible.first?.title == "new TUI title")
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.attempts"))
        let data = try Data(contentsOf: sandbox.root.appendingPathComponent("abc-123.json"))
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(record["tab_id"] == "")
        let queries = terminal.queryCount
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.queryCount == queries)
        terminal.restart()
        #expect(await binding.resolve(event) == "tab-1")
        #expect(terminal.visible.first?.title == "new TUI title")
    }

    @Test func codexRetryUsesTheLatestSnapshotAfterTheTUIOverwritesAMarker() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event(source: .codex)
        event.tty = "/dev/fixture"
        event.settings["GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS"] = "0"
        let terminal = TerminalFixture()
        terminal.overwriteMarkers(1)
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == "tab-1")
        #expect(
            terminal.recorded == [
                "__codex_TAB_MARKER_abc-123__", "__codex_TAB_MARKER_abc-123__", "new TUI title",
            ])
    }

    @Test func failedQueriesStillRestoreTheOnlyKnownTab() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.failQueries([2, 3])
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.recorded.last == "中文\t完整\n标题")
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.json"))
    }

    @Test func ambiguousRecoveryNeverGuessesAnotherTabsTitle() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.setTabs([.init(id: "tab-1", title: "one"), .init(id: "tab-2", title: "two")])
        terminal.failQueries([2, 3])
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.recorded == ["__claude_TAB_MARKER_abc-123__"])
        #expect(terminal.visible[1].title == "two")
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.json"))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.lock"))
    }

    @Test func restorationFailureCannotPublishASuccessfulBinding() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.failRestoration()
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.json"))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.lock"))
    }

    // The three below reproduce 2026-09-17: a terminal query that never returns.
    // Before the deadline existed they did not fail, they hung; the time limit
    // is what turns a regression into a red test instead of a stuck CI job.

    @Test(.timeLimit(.minutes(1)))
    func aQueryThatNeverReturnsIsAbandonedBeforeAnyMarkerIsWritten() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.hangQueries([1])
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock(),
            queryTimeout: 0.05)
        let started = ContinuousClock.now
        #expect(await binding.resolve(event) == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(terminal.recorded.isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: sandbox.root.path + "/applescript-stalled"))
        // A stall is not a denied permission, and not this session's fault.
        let absent = [
            "applescript-unavailable", "abc-123.json", "abc-123.attempts", "abc-123.lock",
        ]
        for name in absent {
            #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/" + name))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aHungMarkerLookupRestoresTheTitleWithoutAskingAgain() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.hangQueries([2])
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock(),
            queryTimeout: 0.05)
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.recorded == ["__claude_TAB_MARKER_abc-123__", "中文\t完整\n标题"])
        #expect(terminal.visible.first?.title == "中文\t完整\n标题")
        // The blocked thread is still blocked: recovery must not queue behind it.
        #expect(terminal.queryCount == 2)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.attempts"))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.lock"))
    }

    @Test(.timeLimit(.minutes(1)))
    func oneStallKeepsOtherProcessesAwayBrieflyAndThenBindingRecovers() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.hangQueries([1])
        let clock = SteppedBindingClock()
        let stalled = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: clock, queryTimeout: 0.05)
        #expect(await stalled.resolve(event) == nil)
        // A second instance stands in for the next hook process.
        let next = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: clock, queryTimeout: 0.05)
        clock.advance(NativeTerminalBinding.stallBackoff - 1)
        #expect(await next.resolve(event) == nil)
        #expect(await stalled.resolve(event) == nil)
        #expect(terminal.queryCount == 1)
        clock.advance(2)
        #expect(await next.resolve(event) == "tab-1")
        #expect(await stalled.existing(event) == "tab-1")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringALookupThatNeverReturnsStillRestoresPromptly() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.hangQueries([2])
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock(),
            queryTimeout: 20, cancelledQueryTimeout: 0.05)
        let work = Task { await binding.resolve(event) }
        for _ in 0..<2000 where terminal.queryCount < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(terminal.queryCount == 2)
        // What SIGTERM does to a hook: its grace period is a few seconds, far
        // short of the full query limit.
        let cancelled = ContinuousClock.now
        work.cancel()
        #expect(await work.value == nil)
        #expect(ContinuousClock.now - cancelled < .seconds(5))
        #expect(terminal.visible.first?.title == "中文\t完整\n标题")
        // Giving up on a cancelled wait is not evidence of a wedged terminal.
        let absent = ["applescript-stalled", "abc-123.marker.json", "abc-123.lock"]
        for name in absent {
            #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/" + name))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aMarkerLeftByAnAbandonedLookupIsUndoneBeforeTheNextBaseline() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.setTabs([.init(id: "tab-1", title: "one"), .init(id: "tab-2", title: "two")])
        terminal.hangQueries([2])
        let clock = SteppedBindingClock()
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: clock, queryTimeout: 0.05)
        // Two tabs and no answer: nothing says which title was ours.
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.visible[0].title == "__claude_TAB_MARKER_abc-123__")
        let record = sandbox.root.path + "/abc-123.marker.json"
        #expect(FileManager.default.fileExists(atPath: record))

        clock.advance(NativeTerminalBinding.stallBackoff + 1)
        #expect(await binding.resolve(event) == "tab-1")
        // Never the marker written back as though it had been the title.
        #expect(
            terminal.recorded == [
                "__claude_TAB_MARKER_abc-123__", "one", "__claude_TAB_MARKER_abc-123__", "one",
            ])
        #expect(terminal.visible.map(\.title) == ["one", "two"])
        #expect(!FileManager.default.fileExists(atPath: record))
    }

    @Test func aRecordAboutAnotherGhosttyProcessIsDiscardedNotApplied() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        try sandbox.write(
            "abc-123.marker.json",
            #"{"marker":"__claude_TAB_MARKER_abc-123__","tty":"/dev/fixture","#
                + #""ghosttyPID":"999","tabs":[{"id":"tab-1","title":"someone else's title"}]}"#)
        let terminal = TerminalFixture()
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == "tab-1")
        #expect(terminal.recorded == ["__claude_TAB_MARKER_abc-123__", "中文\t完整\n标题"])
        #expect(
            !FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.marker.json"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aSessionResumedInAnotherTabRestoresTheOldTabAndBindsTheNewOne() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/old"
        let terminal = TerminalFixture()
        terminal.setTabs([.init(id: "tab-1", title: "one"), .init(id: "tab-2", title: "two")])
        terminal.attach("/dev/old", toTab: 0)
        terminal.attach("/dev/new", toTab: 1)
        terminal.hangQueries([2])
        let clock = SteppedBindingClock()
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: clock, queryTimeout: 0.05)
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.visible.map(\.title) == ["__claude_TAB_MARKER_abc-123__", "two"])

        // The same session, resumed in the second tab.
        clock.advance(NativeTerminalBinding.stallBackoff + 1)
        event.tty = "/dev/new"
        #expect(await binding.resolve(event) == "tab-2")
        #expect(
            terminal.routed == [
                "/dev/old <- __claude_TAB_MARKER_abc-123__", "/dev/old <- one",
                "/dev/new <- __claude_TAB_MARKER_abc-123__", "/dev/new <- two",
            ])
        #expect(terminal.visible.map(\.title) == ["one", "two"])
        #expect(
            !FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.marker.json"))
    }

    @Test func aLeftoverMarkerInAnotherTabIsNeitherBoundNorRestoredAsATitle() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.setTabs([
            .init(id: "tab-1", title: "__claude_TAB_MARKER_abc-123__"),
            .init(id: "tab-2", title: "two"),
        ])
        terminal.attach("/dev/fixture", toTab: 1)
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == "tab-2")
        #expect(terminal.recorded == ["__claude_TAB_MARKER_abc-123__", "two"])
        #expect(terminal.visible.map(\.title) == ["__claude_TAB_MARKER_abc-123__", "two"])
    }

    @Test func aLeftoverMarkerOnThisTerminalWithNoRecordIsNotTakenAsProof() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.setTabs([
            .init(id: "tab-1", title: "__claude_TAB_MARKER_abc-123__"),
            .init(id: "tab-2", title: "two"),
        ])
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        // Nothing tells this tab from one the session has left, so no binding,
        // and no title is written: the only candidate would be the marker.
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.recorded == ["__claude_TAB_MARKER_abc-123__"])
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.json"))
        #expect(
            !FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.marker.json"))
    }

    @Test func aPartialMarkerWriteStillRestoresTheOnlyKnownTitle() async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event()
        event.tty = "/dev/fixture"
        let terminal = TerminalFixture()
        terminal.failPartialMarkerWrite()
        let binding = NativeTerminalBinding(
            automation: terminal, writer: terminal, clock: InstantBindingClock())
        #expect(await binding.resolve(event) == nil)
        #expect(terminal.visible.first?.title == "中文\t完整\n标题")
        #expect(terminal.recorded.count == 2)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.json"))
    }
}

@Suite("Native process and synchronous round capture")
struct NativeProcessTests {
    @Test(arguments: ["invalid", "-1", String(repeating: "9", count: 400)])
    func corruptStartIsZeroRatherThanAnUnencodableEvent(_ value: String) async throws {
        let sandbox = try HookSandbox()
        let input = try sandbox.event()
        try sandbox.write("abc-123.start", value)
        let event = try await DiskRoundJournal().capture(input)
        #expect(event.startedAt == 0)
        #expect(!NotificationPolicy.qualifies(event))
        _ = try HookEvent.decode(JSONEncoder().encode(event))
    }
    @Test func currentProcessIsInspectedWithoutExecutingPs() throws {
        let process = try #require(
            MacProcessInspector().process(ProcessInfo.processInfo.processIdentifier))
        #expect(process.parent > 0)
        #expect(!process.executable.isEmpty)
        #expect(!process.birth.isEmpty)
    }
    @Test func captureKeepsClaudeAndCodexTimingSemantics() async throws {
        let sandbox = try HookSandbox()
        let journal = DiskRoundJournal()
        let prompt = try sandbox.event(kind: .prompt)
        let first = try await journal.capture(prompt)
        #expect(first.startedAt == 0)
        var tool = first
        tool.payload.hookEventName = HookKind.preTool.rawValue
        tool.occurredAt = 2001
        let started = try await journal.capture(tool)
        #expect(started.startedAt == 2001)
        #expect(started.roundID == first.roundID)
        tool.occurredAt = 2002
        #expect(try await journal.capture(tool).startedAt == 2001)
        var codex = prompt
        codex.source = .codex
        let next = try await journal.capture(codex)
        #expect(next.startedAt == 2000)
        #expect(next.roundID != first.roundID)
        await journal.finish(started)
        #expect(DiskRoundJournal.read(sandbox.root.path + "/abc-123.start") == "2000")
    }
}
