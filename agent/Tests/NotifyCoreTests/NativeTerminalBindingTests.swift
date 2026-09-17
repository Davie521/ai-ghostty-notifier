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
    private var queries = 0
    private var unavailable = false
    private var pid: pid_t = 123
    private var misses = 0
    private var queryFailures: [Int: Int] = [:]
    private var partialWrite = false
    private var restorationFailure = false
    private var overwrittenMarkers = 0
    var recorded: [String] { lock.withLock { writes } }
    var queryCount: Int { lock.withLock { queries } }
    var visible: [TerminalTab] { lock.withLock { titles } }
    func failSnapshots() { lock.withLock { unavailable = true } }
    func failQueries(_ numbers: [Int], code: Int = -1712) {
        lock.withLock { for number in numbers { queryFailures[number] = code } }
    }
    func setTabs(_ value: [TerminalTab]) { lock.withLock { titles = value } }
    func failPartialMarkerWrite() { lock.withLock { partialWrite = true } }
    func failRestoration() { lock.withLock { restorationFailure = true } }
    func overwriteMarkers(_ count: Int) { lock.withLock { overwrittenMarkers = count } }
    func restart() { lock.withLock { pid += 1 } }
    func missMarkers(_ count: Int) { lock.withLock { misses = count } }
    func processID() async -> pid_t? { lock.withLock { pid } }
    func tabs() async throws -> [TerminalTab] {
        try lock.withLock {
            queries += 1
            if let code = queryFailures[queries] {
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
            guard !titles.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            if title.contains("TAB_MARKER"), partialWrite {
                partialWrite = false
                titles[0].title = String(title.prefix(12))
                throw CocoaError(.fileWriteUnknown)
            }
            if !title.contains("TAB_MARKER"), restorationFailure {
                throw CocoaError(.fileWriteUnknown)
            }
            if title.contains("TAB_MARKER"), overwrittenMarkers > 0 {
                overwrittenMarkers -= 1
                titles[0].title = "new TUI title"
                return
            }
            titles[0].title = title
        }
    }
    func focus(tabID: String?) async {}
    func isFrontmost() async -> Bool? { false }
    func selectedTabID() async -> String? { nil }
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
