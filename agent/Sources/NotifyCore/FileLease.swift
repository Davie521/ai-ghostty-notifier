import Darwin
import Foundation

/// The lock between hook processes, workers and the resident agent: flock(2) on
/// `<path>.flock`.
///
/// The kernel drops it with its holder, however the holder dies, so there is no
/// stale lock and nothing to recover. The directory lock this replaces had to
/// recover one from a dead holder, and two contenders doing that at once could
/// both end up inside: under load, 3 times in 600 rounds.
///
/// The file stays when the lock is released. Removing it then would let a
/// process that had already opened it lock a file nobody else can see.
public final class FileLease {
    private let descriptor: CInt
    private var released = false
    private init(_ descriptor: CInt) { self.descriptor = descriptor }

    /// `timeout` 0 tries once. Nil when the lock is held elsewhere for that
    /// long, or the file cannot be created.
    public static func acquire(_ path: String, timeout: Double = 1) -> FileLease? {
        let file = path + ".flock"
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            // O_CLOEXEC: a notification backend started while this is held must
            // not inherit the descriptor, and with it the lock.
            let descriptor = open(file, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return nil }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                // Pruning may have removed the file since it was opened. A lock
                // on a file that is no longer at this path excludes nobody.
                var mine = stat()
                var current = stat()
                if fstat(descriptor, &mine) == 0, stat(file, &current) == 0,
                    mine.st_ino == current.st_ino, mine.st_dev == current.st_dev
                {
                    return FileLease(descriptor)
                }
            }
            close(descriptor)
            if ProcessInfo.processInfo.systemUptime >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.01)
        } while true
    }

    /// Removes a lock file nobody holds. Taken first, so that it cannot vanish
    /// from under a holder; a contender that opened it meanwhile notices that
    /// its file has left the path and starts over.
    public static func discard(lockFile: String) {
        guard lockFile.hasSuffix(".flock"),
            let lease = acquire(String(lockFile.dropLast(".flock".count)), timeout: 0)
        else { return }
        unlink(lockFile)
        lease.release()
    }

    public func release() {
        guard !released else { return }
        released = true
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
    deinit { release() }
}
