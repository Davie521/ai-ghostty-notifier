import Darwin
import Foundation
import Testing

@testable import NotifyCore

@Suite("The lock between hook processes")
struct FileLeaseTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "file-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Another process asking for the same lock, through the system's own tool.
    /// 0 when it got the lock, 75 when it was held.
    private func anotherProcessTries(_ lockFile: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-k", "-s", "-t", "0", lockFile, "/usr/bin/true"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func aHeldLockKeepsThreadsAndProcessesOutUntilItIsReleased() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.path + "/abc-123.lock"
        let lease = try #require(FileLease.acquire(path))
        #expect(FileLease.acquire(path, timeout: 0) == nil)
        #expect(try anotherProcessTries(path + ".flock") == 75)
        lease.release()
        #expect(try anotherProcessTries(path + ".flock") == 0)
        #expect(FileLease.acquire(path, timeout: 0) != nil)
    }

    @Test func theLockOfAProcessThatWasKilledIsFreeAtOnce() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.path + "/abc-123.lock"
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = [
            "-c",
            "import fcntl, sys, time; f = open(sys.argv[1], 'a'); "
                + "fcntl.flock(f, fcntl.LOCK_EX); time.sleep(60)",
            path + ".flock",
        ]
        try holder.run()
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }
        // Wait until it really holds the lock.
        let deadline = Date().addingTimeInterval(10)
        var held = false
        while !held, Date() < deadline {
            if FileManager.default.fileExists(atPath: path + ".flock") {
                if let probe = FileLease.acquire(path, timeout: 0) {
                    probe.release()
                } else {
                    held = true
                }
            }
            if !held { usleep(20_000) }
        }
        try #require(held, "the other process never took the lock")
        // No grace period and no recovery: this is what a hook killed by its
        // watchdog, or by the CLI's timeout, leaves behind.
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        #expect(FileLease.acquire(path, timeout: 1) != nil)
    }

    @Test func manyContendersNeverShareTheLock() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = NSLock()
        nonisolated(unsafe) var holders = 0
        nonisolated(unsafe) var overlaps = 0
        nonisolated(unsafe) var acquired = 0
        for round in 0..<40 {
            let path = root.path + "/round-\(round).lock"
            DispatchQueue.concurrentPerform(iterations: 12) { _ in
                guard let lease = FileLease.acquire(path, timeout: 5) else { return }
                inside.withLock {
                    holders += 1
                    acquired += 1
                    if holders > 1 { overlaps += 1 }
                }
                usleep(1000)
                inside.withLock { holders -= 1 }
                lease.release()
            }
        }
        #expect(overlaps == 0)
        #expect(acquired == 40 * 12)
    }

    @Test func pruningRemovesAnIdleLockFileAndLeavesAHeldOne() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let idle = root.path + "/idle.lock"
        let busy = root.path + "/busy.lock"
        FileLease.acquire(idle)?.release()
        let lease = try #require(FileLease.acquire(busy))
        FileLease.discard(lockFile: idle + ".flock")
        FileLease.discard(lockFile: busy + ".flock")
        #expect(!FileManager.default.fileExists(atPath: idle + ".flock"))
        #expect(FileManager.default.fileExists(atPath: busy + ".flock"))
        // Still the same lock afterwards: nobody else can get in.
        #expect(FileLease.acquire(busy, timeout: 0) == nil)
        lease.release()
        // Anything that is not a lock file is not its business.
        try "keep".write(toFile: root.path + "/notes.txt", atomically: true, encoding: .utf8)
        FileLease.discard(lockFile: root.path + "/notes.txt")
        #expect(FileManager.default.fileExists(atPath: root.path + "/notes.txt"))
    }
}
