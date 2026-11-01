import Foundation
import Testing

@testable import NotifyCore

/// `--nudge` takes back a request the agent has not taken within five
/// seconds. Whoever unlinks it first decides whether it is posted, so what
/// `--nudge` reports is what happens.
@Suite struct SpoolWithdrawalTests {
    static func published(_ sandbox: HookSandbox) throws -> (path: String, data: Data) {
        let data = try RequestCodec.encode(.ping)
        return (try AtomicSpool.write(data, to: sandbox.root.path), data)
    }

    @Test func theAgentTakesWhatNobodyTookBack() throws {
        let sandbox = try HookSandbox()
        let request = try Self.published(sandbox)
        #expect(AtomicSpool.take(request.path) == .request(request.data))
        #expect(!FileManager.default.fileExists(atPath: request.path))
    }

    @Test func aRequestTakenBackIsGoneForTheAgent() throws {
        let sandbox = try HookSandbox()
        let request = try Self.published(sandbox)
        #expect(AtomicSpool.withdraw(request.path) == .withdrawn)
        #expect(AtomicSpool.take(request.path) == .gone)
    }

    /// The agent reads a request and then unlinks it. Taken back in between,
    /// the agent must not act on what it read.
    @Test func aRequestTakenBackAfterTheAgentReadItIsStillNotPosted() throws {
        let sandbox = try HookSandbox()
        let request = try Self.published(sandbox)
        let read = try Data(contentsOf: URL(fileURLWithPath: request.path))
        #expect(AtomicSpool.withdraw(request.path) == .withdrawn)
        #expect(AtomicSpool.claim(request.path, read: read) == .gone)
    }

    @Test func aRequestTheAgentTookFirstCannotBeTakenBack() throws {
        let sandbox = try HookSandbox()
        let request = try Self.published(sandbox)
        #expect(AtomicSpool.take(request.path) == .request(request.data))
        #expect(AtomicSpool.withdraw(request.path) == .taken)
    }

    /// Neither side can remove it while the directory is read-only, so
    /// neither acts on it. Once it is writable again (any write restores
    /// 0700) the first unlink decides, as always: here the withdrawal wins,
    /// and the agent, which saw it while it was stuck, never posted it.
    @Test func aRequestThatCannotBeRemovedIsLeftForWhoeverUnlinksItFirst() throws {
        // Root removes it from a read-only directory anyway.
        guard getuid() != 0 else { return }
        let sandbox = try HookSandbox()
        let request = try Self.published(sandbox)
        func writable(_ yes: Bool) throws {
            try FileManager.default.setAttributes(
                [.posixPermissions: yes ? 0o700 : 0o500], ofItemAtPath: sandbox.root.path)
        }
        try writable(false)
        defer { try? writable(true) }
        guard case .stuck(let agentReason) = AtomicSpool.take(request.path),
            case .stuck(let writerReason) = AtomicSpool.withdraw(request.path)
        else {
            Issue.record("a request in a read-only directory was taken or withdrawn")
            return
        }
        #expect(!agentReason.isEmpty && !writerReason.isEmpty)
        #expect(FileManager.default.fileExists(atPath: request.path))
        try writable(true)
        #expect(AtomicSpool.withdraw(request.path) == .withdrawn)
        #expect(AtomicSpool.take(request.path) == .gone)
    }

    @Test func aStuckRequestIsTakenOnceItCanBeRemoved() throws {
        guard getuid() != 0 else { return }
        let sandbox = try HookSandbox()
        let request = try Self.published(sandbox)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: sandbox.root.path)
        let first = AtomicSpool.take(request.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: sandbox.root.path)
        guard case .stuck = first else {
            Issue.record("a request in a read-only directory was taken")
            return
        }
        #expect(AtomicSpool.take(request.path) == .request(request.data))
    }

    @Test func anUnreadableRequestIsDroppedNotRetried() throws {
        let sandbox = try HookSandbox()
        let missing = sandbox.root.appendingPathComponent("gone.json").path
        #expect(AtomicSpool.take(missing) == .gone)
    }
}
