import Darwin
import Foundation

/// Shared with existing installations: mkdir is the cross-process primitive,
/// not actor isolation. Only a dead, stale holder may be recovered.
public final class DirectoryLease {
    private let path: String
    private var released = false
    private init(_ path: String) { self.path = path }

    public static func acquire(_ path: String, timeout: Double = 1, staleAfter: Double = 30)
        -> DirectoryLease?
    {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if mkdir(path, 0o700) == 0 {
                let lease = DirectoryLease(path)
                do {
                    try "\(getpid())\n".write(
                        toFile: path + "/pid", atomically: true, encoding: .utf8)
                    return lease
                } catch { return nil }
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = attributes?[.modificationDate] as? Date ?? Date()
            let owner = pid_t(DiskRoundJournal.read(path + "/pid"))
            let alive = owner.map { $0 > 0 && (kill($0, 0) == 0 || errno != ESRCH) } ?? false
            if Date().timeIntervalSince(modified) > staleAfter, !alive {
                _ = unlink(path + "/pid")
                _ = rmdir(path)
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.01)
        } while true
    }

    public func release() {
        guard !released else { return }
        released = true
        _ = unlink(path + "/pid")
        _ = rmdir(path)
    }
    deinit { release() }
}
