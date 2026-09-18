import Foundation

/// A terminal query that never came back within its wall-clock limit.
///
/// Deliberately not Apple Event error -1712. That code is the *target* replying
/// late, and the call still returns; callers may retry at once. This is the call
/// itself failing to return, which means the thread that made it is still
/// blocked and the next query would queue behind it. See
/// `docs/incident-2026-09-17-pretooluse-hang.md`.
public struct TerminalQueryAbandoned: Error, Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// The full limit passed. Evidence that something is wedged.
        case deadline
        /// The caller was cancelled and the shorter limit passed. Evidence of
        /// nothing: an ordinary query may simply not have finished yet.
        case cancelled
    }
    public var cause: Cause
    public init(_ cause: Cause = .deadline) { self.cause = cause }
}

/// Races work that may be impossible to cancel against a deadline.
///
/// Structured concurrency cannot express this: a task group waits for every
/// child before it returns, so one blocked `NSAppleScript` call would hold the
/// group, and everything awaiting it, for as long as the call stays blocked.
/// Both sides therefore run unstructured and the loser's result is dropped. An
/// abandoned operation is cancelled as a courtesy to cooperative work; nothing
/// here relies on that cancellation being observed.
///
/// Cancelling the caller shortens the limit instead of ending the wait. Cleanup
/// runs in cancelled tasks and still needs answers (title restoration looks its
/// marker up after a newer prompt cancels the binding), so a healthy query must
/// be allowed to finish. A shutdown grace period, though, cannot sit out the
/// full limit behind a query that will never return.
public enum QueryDeadline {
    private final class Race<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, any Error>?
        private var timers: [Task<Void, Never>] = []
        private var work: Task<Void, Never>?
        private var cancelledLimit: Double?

        /// Before the work starts: a result that arrived first would have no
        /// continuation to resume and would be lost until the deadline.
        func begin(_ continuation: CheckedContinuation<Value, any Error>) {
            let limit = lock.withLock { () -> Double? in
                self.continuation = continuation
                return cancelledLimit
            }
            // The caller was cancelled before there was anything to shorten.
            if let limit { expire(after: limit, as: .cancelled) }
        }

        func adopt(_ work: Task<Void, Never>) {
            let finished = lock.withLock { () -> Bool in
                self.work = work
                return continuation == nil
            }
            if finished { work.cancel() }
        }

        func callerCancelled(limit: Double) {
            let started = lock.withLock { () -> Bool in
                cancelledLimit = limit
                return continuation != nil
            }
            if started { expire(after: limit, as: .cancelled) }
        }

        func expire(after seconds: Double, as cause: TerminalQueryAbandoned.Cause) {
            let timer = Task {
                do { try await Task.sleep(for: .seconds(max(0, seconds))) } catch { return }
                if self.finish(.failure(TerminalQueryAbandoned(cause))) {
                    self.lock.withLock { self.work }?.cancel()
                }
            }
            lock.withLock { timers.append(timer) }
        }

        /// True for the one caller whose result was delivered.
        @discardableResult func finish(_ result: Result<Value, any Error>) -> Bool {
            let (pending, timers) = lock.withLock {
                () -> (CheckedContinuation<Value, any Error>?, [Task<Void, Never>]) in
                defer { continuation = nil }
                return (continuation, self.timers)
            }
            guard let pending else { return false }
            for timer in timers { timer.cancel() }
            pending.resume(with: result)
            return true
        }
    }

    public static func run<Value: Sendable>(
        seconds: Double, cancelledSeconds: Double? = nil,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.begin(continuation)
                race.expire(after: seconds, as: .deadline)
                race.adopt(
                    Task {
                        let result: Result<Value, any Error>
                        do { result = .success(try await operation()) } catch {
                            result = .failure(error)
                        }
                        race.finish(result)
                    })
            }
        } onCancel: {
            if let cancelledSeconds { race.callerCancelled(limit: cancelledSeconds) }
        }
    }
}
