import AppKit

/// Must run before any `NSAppleScript` executes off the main thread.
///
/// `NSAppleScript` waits for its reply by pumping a Carbon event loop on the
/// calling thread. That only works once AppKit has claimed the main thread:
/// without it the first Carbon call claims the *calling* thread instead (the
/// system logs "Main thread potentially initialized incorrectly"), the reply
/// is never serviced there, and neither is the script's own `with timeout`.
/// The send then blocks until something unrelated wakes the thread.
///
/// The resident app always had an `NSApplication`. The short-lived hook,
/// worker, focus and clear modes did not, which is how PreToolUse hooks came to
/// block for the CLI's whole 600-second hook timeout on 2026-09-17. Measured
/// with the production tab query, twenty runs per arm: background queue without
/// NSApplication 0/20 returned inside six seconds; with it 20/20 in about
/// 0.28 s. See `docs/incident-2026-09-17-pretooluse-hang.md`.
///
/// Creating the instance is enough. No mode needs `run()`: each already keeps
/// the main run loop alive, which is what services the reply.
@MainActor
enum AppleEventHost {
    static func prepare() { _ = NSApplication.shared }
}
