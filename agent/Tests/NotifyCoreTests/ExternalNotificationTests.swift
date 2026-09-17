import Foundation
import Testing

@testable import NotifyCore

private final class TickClock: HookClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 2000
    func now() -> Double { lock.withLock { time } }
    func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        lock.withLock { time += seconds }
        await Task.yield()
    }
}
private actor FocusFixture: TerminalAutomationProviding {
    private var fronts: [Bool?]
    private var selected: [String?]
    private(set) var queries = 0
    private(set) var focusCalls: [String?] = []
    init(fronts: [Bool?] = [false], selected: [String?] = [nil]) {
        self.fronts = fronts
        self.selected = selected
    }
    func processID() -> Int32? { 123 }
    func tabs() -> [TerminalTab] { [] }
    func focus(tabID: String?) { focusCalls.append(tabID) }
    func isFrontmost() -> Bool? {
        queries += 1
        return fronts.count > 1 ? fronts.removeFirst() : fronts.first!
    }
    func selectedTabID() -> String? {
        selected.count > 1 ? selected.removeFirst() : selected.first!
    }
}
private struct FinishedCommand: RunningCommand {
    var value: CommandResult
    var pid: Int32 { 987654 }
    var isRunning: Bool { false }
    func result(timeout: Double?) async -> CommandResult { value }
    func cancel() {}
}
private final class RecordingCommands: CommandLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, [String])] = []
    let alerterStatus: Int32
    let terminalStatus: Int32
    let action: String
    let failLaunch: Bool
    var recorded: [(String, [String])] { lock.withLock { calls } }
    init(
        alerterStatus: Int32 = 0, terminalStatus: Int32 = 0, action: String = "Dismiss",
        failLaunch: Bool = false
    ) {
        self.alerterStatus = alerterStatus
        self.terminalStatus = terminalStatus
        self.action = action
        self.failLaunch = failLaunch
    }
    func start(executable: String, arguments: [String]) throws -> any RunningCommand {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        lock.withLock { calls.append((name, arguments)) }
        if arguments == ["--help"] {
            return FinishedCommand(value: .init(status: 0, output: "--close-label --remove"))
        }
        if arguments.first?.contains("remove") == true {
            return FinishedCommand(value: .init(status: 0))
        }
        if failLaunch { throw CocoaError(.executableNotLoadable) }
        return FinishedCommand(
            value: .init(
                status: name == "alerter" ? alerterStatus : terminalStatus,
                output: action))
    }
}
private final class ProcessAndSignalFixture: ProcessInspecting, ProcessSignalling,
    @unchecked Sendable
{
    private let lock = NSLock()
    var value: HostProcess?
    var argv: [String] = []
    var changesBirth = false
    private var reads = 0
    private var signals: [Int32] = []
    var terminated: [Int32] { lock.withLock { signals } }
    func process(_ pid: Int32) -> HostProcess? {
        lock.withLock {
            reads += 1
            var current = value
            if changesBirth, reads > 1 { current?.birth = "reused" }
            return current?.pid == pid ? current : nil
        }
    }
    func arguments(_ pid: Int32) -> [String] { argv }
    func terminate(_ pid: Int32) { lock.withLock { signals.append(pid) } }
}

@Suite("Native external notification lifecycle")
struct ExternalNotificationTests {
    private func event(_ sandbox: HookSandbox, backend: String = "alerter", clear: Bool = false)
        throws -> HookEvent
    {
        var event = try sandbox.event()
        for file in ["alerter", "terminal-notifier"] {
            try sandbox.write(file, "fixture")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sandbox.root.path + "/" + file)
        }
        event.homeDirectory = sandbox.root.path
        event.searchPath = sandbox.root.path
        event.settings["GHOSTTY_NOTIFY_ALERTER"] = sandbox.root.path + "/alerter"
        event.settings["GHOSTTY_NOTIFY_BACKEND"] = backend
        event.settings["GHOSTTY_NOTIFY_CLEAR_ON_FOCUS"] = clear ? "1" : "0"
        event.settings["GHOSTTY_NOTIFY_TIMEOUT"] = "1"
        return event
    }
    @Test(arguments: ["Dismiss", "@CLOSED", "@TIMEOUT", "", "Go to tab", "@CONTENTCLICKED"])
    func displayOnlyFallbackNeverDispatchesActions(_ action: String) async throws {
        let sandbox = try HookSandbox()
        let event = try event(sandbox)
        let commands = RecordingCommands(action: action)
        let focus = FocusFixture()
        let external = ExternalNotifications(
            automation: focus, launcher: commands, clock: TickClock())
        await external.deliver(
            NotificationPolicy.content(event, title: "中文", tabID: "tab-1"), event: event)
        #expect(await focus.focusCalls.isEmpty)
        #expect(await focus.queries == 0)
        #expect(commands.recorded.count == 1)
        #expect(commands.recorded.first?.0 == "terminal-notifier")
        #expect(commands.recorded.first?.1.contains("-execute") == false)
        #expect(
            FileManager.default.fileExists(
                atPath: sandbox.root.path + "/abc-123.native-notice.json"))
    }
    @Test func failedFallbackLaunchDoesNotStartAnotherBackend() async throws {
        let sandbox = try HookSandbox()
        let event = try event(sandbox)
        let commands = RecordingCommands(failLaunch: true)
        let focus = FocusFixture()
        let external = ExternalNotifications(
            automation: focus, launcher: commands, clock: TickClock())
        await external.deliver(
            NotificationPolicy.content(event, title: "", tabID: nil), event: event)
        #expect(commands.recorded.count == 1)
        #expect(commands.recorded.first?.0 == "terminal-notifier")
        #expect(await focus.focusCalls.isEmpty)
    }
    @Test func terminalNotifierFailureStartsNoFocusWatcher() async throws {
        let sandbox = try HookSandbox()
        let event = try event(sandbox, backend: "terminal-notifier", clear: true)
        let focus = FocusFixture()
        let external = ExternalNotifications(
            automation: focus,
            launcher: RecordingCommands(terminalStatus: 1), clock: TickClock())
        await external.deliver(
            NotificationPolicy.content(event, title: "", tabID: nil), event: event)
        #expect(await focus.queries == 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: sandbox.root.path + "/abc-123.native-notice.json"))
    }
    @Test func fallbackReturnsWithoutPollingEvenWhenClearingIsEnabled() async throws {
        let sandbox = try HookSandbox()
        var event = try event(sandbox, backend: "auto", clear: true)
        event.settings["GHOSTTY_NOTIFY_TIMEOUT"] = "0"
        let focus = FocusFixture(fronts: [true], selected: ["tab-1"])
        let commands = RecordingCommands()
        let external = ExternalNotifications(
            automation: focus, launcher: commands, clock: TickClock())
        await external.deliver(
            NotificationPolicy.content(event, title: "", tabID: "tab-1"), event: event)
        #expect(await focus.queries == 0)
        #expect(await focus.focusCalls.isEmpty)
        #expect(commands.recorded.count == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: sandbox.root.path + "/abc-123.native-notice.json"))
    }
    @Test func latePromptCannotRemoveItsOwnRoundButExplicitClearCan() async throws {
        let sandbox = try HookSandbox()
        var event = try event(sandbox, backend: "terminal-notifier")
        let commands = RecordingCommands()
        let external = ExternalNotifications(
            automation: FocusFixture(), launcher: commands, clock: TickClock())
        await external.deliver(
            NotificationPolicy.content(event, title: "", tabID: nil), event: event)
        event.settings["GHOSTTY_NOTIFY_CLEAR_ON_FOCUS"] = "1"
        event.payload.hookEventName = HookKind.prompt.rawValue
        await external.clear(event)
        #expect(!commands.recorded.contains { $0.1.first?.contains("remove") == true })
        await external.clear(event, force: true)
        #expect(commands.recorded.contains { $0.1.first == "-remove" })
    }
    @Test func completedMigrationDoesNotProbeBackendsEveryPrompt() async throws {
        let sandbox = try HookSandbox()
        let event = try event(sandbox, clear: true)
        let commands = RecordingCommands()
        let external = ExternalNotifications(
            automation: FocusFixture(), launcher: commands, clock: TickClock())
        await external.clear(event)
        let firstCount = commands.recorded.count
        #expect(firstCount > 0)
        await external.clear(event)
        #expect(commands.recorded.count == firstCount)
    }
    @Test(arguments: ["same", "different-group", "reused-pid"])
    func legacyPIDRequiresExactGroupAndUnchangedBirth(_ scenario: String) async throws {
        let sandbox = try HookSandbox()
        var event = try event(sandbox, clear: true)
        event.occurredAt = Date().timeIntervalSince1970 + 1
        try sandbox.write("abc-123.alerter-pid", "456789\n")
        let process = ProcessAndSignalFixture()
        process.value = HostProcess(
            pid: 456789, parent: 1, name: "alerter", executable: sandbox.root.path + "/alerter",
            tty: nil, birth: "old")
        process.argv = [
            "alerter", "--group",
            scenario == "different-group" ? "other-session" : "ghostty-notify-abc-123",
        ]
        process.changesBirth = scenario == "reused-pid"
        let external = ExternalNotifications(
            automation: FocusFixture(), launcher: RecordingCommands(),
            inspector: process, signaller: process, clock: TickClock())
        await external.clear(event)
        #expect(process.terminated == (scenario == "same" ? [456789] : []))
    }
    @Test func pruneCannotDeleteUnrelatedFilesInAnOverriddenDirectory() async throws {
        let sandbox = try HookSandbox()
        var event = try event(sandbox)
        event.occurredAt = Date().timeIntervalSince1970
        for name in ["user.json", "settings.json", "ＡＢＣ.json", "abc-123.title"] {
            try sandbox.write(name, "preserve unless owned")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 0)],
                ofItemAtPath: sandbox.root.path + "/" + name)
        }
        await DiskRoundJournal().prepare(event)
        #expect(FileManager.default.fileExists(atPath: sandbox.root.path + "/user.json"))
        #expect(FileManager.default.fileExists(atPath: sandbox.root.path + "/settings.json"))
        #expect(FileManager.default.fileExists(atPath: sandbox.root.path + "/ＡＢＣ.json"))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.title"))
    }
}
