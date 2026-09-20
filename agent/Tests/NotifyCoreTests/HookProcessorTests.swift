import Foundation
import Testing

@testable import NotifyCore

private struct FixedClock: HookClockProviding {
    var instant: Double = 2000
    func now() -> Double { instant }
    func sleep(seconds: Double) async throws { try Task.checkCancellation() }
}

private actor SettlingClock: HookClockProviding {
    var requested: Double?
    var release: CheckedContinuation<Void, Never>?
    nonisolated func now() -> Double { 2000 }
    func sleep(seconds: Double) async throws {
        requested = seconds
        await withCheckedContinuation { release = $0 }
        try Task.checkCancellation()
    }
    func waitUntilSettling() async throws {
        for _ in 0..<1000 {
            if release != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CocoaError(.executableRuntimeMismatch)
    }
    func resume() {
        release?.resume()
        release = nil
    }
}

private actor JournalSpy: RoundJournalProviding {
    var round = "2000-123-1"
    var finished: [String] = []
    var claims = 0
    var allow = true
    func isCurrent(_ event: HookEvent) -> Bool { event.roundID == round }
    func changeRound(_ value: String) { round = value }
    func prepare(_ event: HookEvent) {}
    func finish(_ event: HookEvent) { if event.roundID == round { finished.append(event.roundID) } }
    func claimRate(_ event: HookEvent, now: Double) -> Bool {
        claims += 1
        return allow
    }
}

private actor PreparingJournal: RoundJournalProviding {
    var release: CheckedContinuation<Void, Never>?
    func isCurrent(_ event: HookEvent) -> Bool { true }
    func prepare(_ event: HookEvent) async {
        await withCheckedContinuation { release = $0 }
    }
    func finish(_ event: HookEvent) {}
    func claimRate(_ event: HookEvent, now: Double) -> Bool { true }
    func waitUntilPreparing() async throws {
        for _ in 0..<1000 {
            if release != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CocoaError(.executableRuntimeMismatch)
    }
    func resume() {
        release?.resume()
        release = nil
    }
}

private actor ContentGate: SessionContentProviding {
    let blocked: Bool
    var continuing: Bool
    var entered = false
    var release: CheckedContinuation<String, Never>?
    init(blocked: Bool = false, continuing: Bool = false) {
        self.blocked = blocked
        self.continuing = continuing
    }
    func title(for event: HookEvent) async -> String {
        entered = true
        if blocked { return await withCheckedContinuation { release = $0 } }
        return "resolved title"
    }
    func isContinuing(_ event: HookEvent) -> Bool { continuing }
    func setContinuing() { continuing = true }
    func resume() {
        release?.resume(returning: "old title")
        release = nil
    }
    func waitUntilEntered() async throws {
        for _ in 0..<1000 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CocoaError(.executableRuntimeMismatch)
    }
}

private actor BindingSpy: TerminalBindingProviding {
    var resolved = 0
    func existing(_ event: HookEvent) -> String? { "tab-1" }
    func resolve(_ event: HookEvent) -> String? {
        resolved += 1
        return "tab-1"
    }
    func clearExternal(_ event: HookEvent) {}
}

@Suite("Native asynchronous hook lifecycle")
@MainActor
struct HookProcessorTests {
    @Test(arguments: [HookKind.prompt, .stop])
    func shutdownDuringIntakeCannotCreateUncancelledWork(kind: HookKind) async throws {
        let journal = PreparingJournal()
        let binding = BindingSpy()
        let content = ContentGate()
        var prompts = 0
        var notices = 0
        let processor = HookProcessor(
            journal: journal, content: content, binding: binding, clock: FixedClock(),
            onPrompt: { _, _ in prompts += 1 }, onNotify: { _, _ in notices += 1 })
        let work = processor.receive(sampleEvent(kind: kind, source: .codex))
        try await journal.waitUntilPreparing()
        let shutdown = Task { await processor.shutdown() }
        for _ in 0..<1000 {
            if work.isCancelled { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(work.isCancelled)
        await journal.resume()
        await shutdown.value
        await work.value
        #expect(prompts == 0)
        #expect(notices == 0)
        #expect(await binding.resolved == 0)
        #expect(await content.entered == false)
    }

    @Test func shutdownWaitsForPendingCleanupAndRejectsFurtherEvents() async throws {
        let content = ContentGate(blocked: true)
        let processor = HookProcessor(
            journal: JournalSpy(), content: content,
            binding: BindingSpy(), clock: FixedClock(), onPrompt: { _, _ in },
            onNotify: { _, _ in Issue.record("shutdown allowed a notification") })
        let work = processor.receive(sampleEvent())
        try await content.waitUntilEntered()
        var stopped = false
        let shutdown = Task {
            await processor.shutdown()
            stopped = true
        }
        await Task.yield()
        #expect(!stopped)
        await content.resume()
        await shutdown.value
        await work.value
        #expect(stopped)
        await processor.receive(sampleEvent()).value
    }
    @Test func newPromptCancelsCodexWhileItIsSettling() async throws {
        let journal = JournalSpy()
        let clock = SettlingClock()
        let content = ContentGate()
        let binding = BindingSpy()
        var notices: [NotifyRequest] = []
        let processor = HookProcessor(
            journal: journal, content: content, binding: binding, clock: clock,
            onPrompt: { _, _ in }, onNotify: { _, notice in notices.append(notice) })
        let stop = processor.receive(sampleEvent(source: .codex))
        try await clock.waitUntilSettling()
        #expect(await clock.requested == 1.5)
        var prompt = sampleEvent(kind: .prompt, source: .codex)
        prompt.roundID = "new-round"
        await journal.changeRound(prompt.roundID)
        await processor.receive(prompt).value
        await clock.resume()
        await stop.value
        #expect(notices.isEmpty)
        #expect(await content.entered == false)
        #expect(await binding.resolved == 0)
        #expect(await journal.finished.isEmpty)
        #expect(await journal.claims == 0)
    }

    @Test func oldTitleResultCannotResurrectAfterNewPrompt() async throws {
        let journal = JournalSpy()
        let content = ContentGate(blocked: true)
        let binding = BindingSpy()
        var notices: [NotifyRequest] = []
        var prompts: [String] = []
        let processor = HookProcessor(
            journal: journal, content: content, binding: binding, clock: FixedClock(),
            onPrompt: { event, _ in prompts.append(event.roundID) },
            onNotify: { _, notice in notices.append(notice) })
        let work = processor.receive(sampleEvent())
        try await content.waitUntilEntered()
        var prompt = sampleEvent(kind: .prompt)
        prompt.roundID = "new-round"
        await journal.changeRound(prompt.roundID)
        await processor.receive(prompt).value
        await content.resume()
        await work.value
        #expect(notices.isEmpty)
        #expect(prompts == ["new-round"])
        #expect(await journal.finished.isEmpty)
        #expect(await journal.claims == 0)
    }

    @Test func diskGenerationProtectsEvenBeforePromptIsDrained() async throws {
        let journal = JournalSpy()
        let content = ContentGate(blocked: true)
        var notices: [NotifyRequest] = []
        let processor = HookProcessor(
            journal: journal, content: content, binding: BindingSpy(), clock: FixedClock(),
            onPrompt: { _, _ in }, onNotify: { _, notice in notices.append(notice) })
        let work = processor.receive(sampleEvent())
        try await content.waitUntilEntered()
        await journal.changeRound("already-written-by-hook")
        await content.resume()
        await work.value
        #expect(notices.isEmpty)
        #expect(await journal.finished.isEmpty)
    }

    @Test func duplicatePendingStopsOnlyStartOneLookup() async throws {
        let journal = JournalSpy()
        let content = ContentGate(blocked: true)
        var notices: [NotifyRequest] = []
        let processor = HookProcessor(
            journal: journal, content: content, binding: BindingSpy(), clock: FixedClock(),
            onPrompt: { _, _ in }, onNotify: { _, notice in notices.append(notice) })
        let first = processor.receive(sampleEvent())
        try await content.waitUntilEntered()
        await processor.receive(sampleEvent()).value
        await content.resume()
        await first.value
        #expect(notices.count == 1)
        #expect(await journal.claims == 1)
    }

    @Test func continuationKeepsClockAndSkipsBinding() async {
        let journal = JournalSpy()
        let binding = BindingSpy()
        var notices: [NotifyRequest] = []
        let processor = HookProcessor(
            journal: journal, content: ContentGate(continuing: true), binding: binding,
            clock: FixedClock(),
            onPrompt: { _, _ in }, onNotify: { _, notice in notices.append(notice) })
        await processor.receive(sampleEvent(source: .codex)).value
        #expect(notices.isEmpty)
        #expect(await journal.finished.isEmpty)
        #expect(await journal.claims == 0)
        #expect(await binding.resolved == 0)
    }

    @Test func expiredEventDoesNoTitleOrTerminalWork() async {
        let journal = JournalSpy()
        let binding = BindingSpy()
        let content = ContentGate()
        var notices: [NotifyRequest] = []
        let processor = HookProcessor(
            journal: journal, content: content, binding: binding, clock: FixedClock(instant: 2301),
            onPrompt: { _, _ in }, onNotify: { _, notice in notices.append(notice) })
        await processor.receive(sampleEvent()).value
        #expect(notices.isEmpty)
        #expect(await binding.resolved == 0)
        #expect(await content.entered == false)
    }

    @Test func shortRoundFinishesWithoutReservingRateSlot() async {
        let journal = JournalSpy()
        let binding = BindingSpy()
        let processor = HookProcessor(
            journal: journal, content: ContentGate(), binding: binding, clock: FixedClock(),
            onPrompt: { _, _ in }, onNotify: { _, _ in Issue.record("short round notified") })
        var event = sampleEvent()
        event.startedAt = 1999
        await processor.receive(event).value
        #expect(await journal.finished == [event.roundID])
        #expect(await journal.claims == 0)
        #expect(await binding.resolved == 0)
    }

    @Test func continuationThatStartsDuringTitleLookupAlsoKeepsTheRound() async throws {
        let journal = JournalSpy()
        let content = ContentGate(blocked: true)
        var notices: [NotifyRequest] = []
        let processor = HookProcessor(
            journal: journal, content: content, binding: BindingSpy(), clock: FixedClock(),
            onPrompt: { _, _ in }, onNotify: { _, notice in notices.append(notice) })
        let work = processor.receive(sampleEvent(source: .codex))
        try await content.waitUntilEntered()
        await content.setContinuing()
        await content.resume()
        await work.value
        #expect(notices.isEmpty)
        #expect(await journal.finished.isEmpty)
        #expect(await journal.claims == 0)
    }
}
