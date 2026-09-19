import Darwin
import Foundation
import NotifyCore

/// Last-resort bounds for the short-lived native modes.
///
/// Every other bound in those modes lives on a path that can itself be blocked:
/// reading stdin, an actor hop, the main run loop, an Apple Event behind an
/// unanswered Automation prompt. This one does not. It runs on its own queue,
/// is armed before stdin is read, and ends the process with `_exit`, which
/// needs no cooperation from whatever is stuck.
///
/// A hook exists to decorate the CLI's work, never to hold it. Claude Code
/// waits up to 600 seconds for a command hook by default, so without this a
/// stuck hook reads, from the user's side, as a hung session.
enum NativeLifecycle {
    private static let queue = DispatchQueue(label: "ghostty.native-lifecycle", qos: .userInitiated)
    /// Diagnostics get their own queue. Writing them is I/O, and I/O can block:
    /// a CLI that is not draining the hook's stderr, a stalled volume under the
    /// log. The deadline must not end up waiting on the thing it reports.
    /// Not a background priority: the exit below waits only a moment for the
    /// report, and on a busy machine a utility queue may not run in that moment.
    private static let diagnostics = DispatchQueue(
        label: "ghostty.native-lifecycle.diagnostics", qos: .userInitiated)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var due: DispatchTime?
    nonisolated(unsafe) private static var termination: DispatchSourceSignal?
    nonisolated(unsafe) private static var work: Task<Void, Never>?
    nonisolated(unsafe) private static var terminated = false

    /// Seconds a mode may run. A hook gets a multiple of its slowest honest
    /// run (three bounded terminal queries). A worker's event expires after
    /// `staleNotifyAge`, and nothing it starts outlives that by much.
    static func budget(mode: String, environment: [String: String]) -> Double {
        switch mode {
        case "--hook":
            let value = environment["GHOSTTY_NOTIFY_HOOK_DEADLINE"].flatMap(Double.init)
            guard let value, value.isFinite else { return 12 }
            return min(120, max(1, value))
        case "--worker": return AgentConstants.staleNotifyAge + 30
        default: return 15
        }
    }

    /// The deadline only ever moves earlier. SIGTERM may shorten a budget to
    /// its grace period, but nothing can push the end of the process back: a
    /// supervisor that repeats its signal would otherwise renew the grace each
    /// time and keep a stuck hook alive for as long as it kept asking.
    static func arm(seconds: Double, reason: String, logPath: String?) {
        let wanted = DispatchTime.now() + seconds
        // Decided before the source exists: an inactive source must not be
        // released, so one is only made when it will be resumed.
        let sooner = lock.withLock { () -> Bool in
            if let due, due <= wanted { return false }
            due = wanted
            return true
        }
        guard sooner else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: wanted)
        source.setEventHandler {
            let message = "native lifecycle: \(reason); exiting after \(seconds)s"
            let reported = DispatchSemaphore(value: 0)
            diagnostics.async {
                // A raw write: FileHandle raises on a closed pipe, and the
                // default SIGPIPE action would turn this exit into a failure.
                signal(SIGPIPE, SIG_IGN)
                let line = Array(("ghostty-notify: " + message + "\n").utf8)
                _ = line.withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress, $0.count) }
                if let logPath { AgentLog.append(message, to: logPath) }
                reported.signal()
            }
            // Long enough for a healthy write, and not a moment of dependence
            // on an unhealthy one.
            _ = reported.wait(timeout: .now() + 0.25)
            // Success on purpose: a notification problem is not the CLI's error.
            _exit(0)
        }
        let previous = lock.withLock { () -> DispatchSourceTimer? in
            defer { timer = source }
            return timer
        }
        previous?.cancel()
        source.resume()
    }

    /// SIGTERM cancels the work and then allows `grace` seconds for cleanup
    /// (title restoration, reaping a notification backend). The grace has to
    /// cover what cancelled cleanup may still wait for: a cancelled terminal
    /// query is given up after one second, and restoration can need two. Off the main queue,
    /// so a blocked main thread cannot swallow the signal, and with a deadline,
    /// because the waits that matter most here do not observe cancellation.
    static func installTermination(grace: Double, logPath: String?) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler {
            let (first, task) = lock.withLock { () -> (Bool, Task<Void, Never>?) in
                defer { terminated = true }
                return (!terminated, work)
            }
            // One grace period, counted from the first signal.
            guard first else { return }
            task?.cancel()
            arm(seconds: grace, reason: "cleanup outlived SIGTERM", logPath: logPath)
        }
        lock.withLock { termination = source }
        source.resume()
    }

    /// The work starts after stdin is drained, which can be after the signal.
    static func adopt(_ task: Task<Void, Never>) {
        let late = lock.withLock { () -> Bool in
            work = task
            return terminated
        }
        if late { task.cancel() }
    }
}
