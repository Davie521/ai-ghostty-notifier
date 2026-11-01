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
        #expect(AtomicSpool.take(request.path) == request.data)
        #expect(!FileManager.default.fileExists(atPath: request.path))
    }

    @Test func aRequestTakenBackIsGoneForTheAgent() throws {
        let sandbox = try HookSandbox()
        let request = try Self.published(sandbox)
        #expect(AtomicSpool.withdraw(request.path) == .withdrawn)
        #expect(AtomicSpool.take(request.path) == nil)
    }

    /// The agent reads a request and then unlinks it. Taken back in between,
    /// the agent must not act on what it read.
    @Test func aRequestTakenBackAfterTheAgentReadItIsStillNotPosted() throws {
        let sandbox = try HookSandbox()
        let request = try Self.published(sandbox)
        let read = try Data(contentsOf: URL(fileURLWithPath: request.path))
        #expect(AtomicSpool.withdraw(request.path) == .withdrawn)
        #expect(AtomicSpool.claim(request.path, read: read) == nil)
    }

    @Test func aRequestTheAgentTookFirstCannotBeTakenBack() throws {
        let sandbox = try HookSandbox()
        let request = try Self.published(sandbox)
        #expect(AtomicSpool.take(request.path) == request.data)
        #expect(AtomicSpool.withdraw(request.path) == .taken)
    }

    @Test func aRequestThatCannotBeRemovedIsReportedAsStillThere() throws {
        // Root removes it from a read-only directory anyway.
        guard getuid() != 0 else { return }
        let sandbox = try HookSandbox()
        let request = try Self.published(sandbox)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: sandbox.root.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: sandbox.root.path)
        }
        guard case .stuck(let reason) = AtomicSpool.withdraw(request.path) else {
            Issue.record("a request in a read-only directory was reported gone")
            return
        }
        #expect(!reason.isEmpty)
        #expect(FileManager.default.fileExists(atPath: request.path))
        // Not lost for a permissions problem: the agent still gets it.
        #expect(AtomicSpool.take(request.path) == request.data)
    }

    @Test func anUnreadableRequestIsDroppedNotRetried() throws {
        let sandbox = try HookSandbox()
        let missing = sandbox.root.appendingPathComponent("gone.json").path
        #expect(AtomicSpool.take(missing) == nil)
    }
}
