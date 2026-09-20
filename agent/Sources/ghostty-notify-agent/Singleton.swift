import Darwin
import Foundation
import NotifyCore

/// Guards against a second agent.
///
/// Two agents draining one spool split requests arbitrarily — the drain unlinks
/// each file before decoding it, so whichever wakes first takes it — and both
/// write `state.json`, so the loser's bookkeeping is silently clobbered. A
/// notification one instance posted then cannot be withdrawn by the other,
/// because only one of them knows the session.
///
/// Two are easy to end up with: `open -a` reuses a running app (LaunchServices
/// enforces one instance), but launchd starting the binary directly bypasses
/// that rule entirely — and the install flow needs both, because a
/// launchd-exec'd agent cannot obtain notification authorization while an
/// `open`-launched one can.
///
/// The incumbent wins and the newcomer exits cleanly. The LaunchAgent's
/// KeepAlive is set to restart only on a *failed* exit, so this cannot spin.
enum Singleton {
    /// Held from here until the process ends, and released by the kernel when
    /// it does, however it ends. Never read after it is set.
    nonisolated(unsafe) private static var claimed: FileLease?

    /// True when this process is now the agent for `paths`.
    ///
    /// A lock, not a look at the pid file: the pid is written once the app has
    /// finished launching, so agents started together all found no incumbent
    /// and all stayed. Three started at once were three running, every time.
    ///
    /// Called before the app finishes launching, so it must not touch anything
    /// from UserNotifications: a file lock is safe there, and
    /// `UNUserNotificationCenter.current()` is emphatically not.
    static func claim(paths: AgentPaths) -> Bool {
        try? PrivateFile.createDirectory(paths.root)
        claimed = FileLease.acquire(paths.root + "/agent", timeout: 0)
        return claimed != nil
    }
}
