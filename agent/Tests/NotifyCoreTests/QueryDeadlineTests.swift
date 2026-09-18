import Foundation
import Testing

@testable import NotifyCore

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false
    /// Suspends without observing cancellation, like a blocked NSAppleScript.
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiting = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func open() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { waiting = nil }
            return waiting
        }
        pending?.resume()
    }
}

@Suite("Deadline for work that cannot be cancelled")
struct QueryDeadlineTests {
    @Test func promptWorkReturnsItsOwnValueAndError() async throws {
        #expect(try await QueryDeadline.run(seconds: 5) { 42 } == 42)
        await #expect(throws: CocoaError.self) {
            try await QueryDeadline.run(seconds: 5) { () -> Int in
                throw CocoaError(.fileNoSuchFile)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func workThatIgnoresCancellationIsAbandonedNotAwaited() async throws {
        let gate = Gate()
        let started = ContinuousClock.now
        await #expect(throws: TerminalQueryAbandoned.self) {
            try await QueryDeadline.run(seconds: 0.05) { () -> Int in
                await gate.wait()
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        // Its late result has nowhere to go and must not trap on a double resume.
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledCallerWaitsOnlyTheShorterLimit() async throws {
        let gate = Gate()
        let started = ContinuousClock.now
        let caller = Task {
            // Twenty seconds, not an hour: if the shorter limit ever stops
            // applying, this fails on the elapsed check instead of hanging CI.
            try await QueryDeadline.run(seconds: 20, cancelledSeconds: 0.05) { () -> Int in
                await gate.wait()
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        await #expect(throws: TerminalQueryAbandoned(.cancelled)) { try await caller.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        gate.open()
    }

    // Title restoration runs in cancelled tasks. Ending the wait at the moment
    // of cancellation would take its answer away and leave a marker on the tab.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledCallerStillGetsAnAnswerThatArrivesInTime() async throws {
        let gate = Gate()
        let caller = Task {
            try await QueryDeadline.run(seconds: 30, cancelledSeconds: 30) { () -> Int in
                await gate.wait()
                return 7
            }
        }
        caller.cancel()
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        #expect(try await caller.value == 7)
    }
}
