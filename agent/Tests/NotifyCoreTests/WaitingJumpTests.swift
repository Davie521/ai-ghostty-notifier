import Foundation
import Testing

@testable import NotifyCore

@Suite("--jump-waiting decides before it asks")
struct WaitingJumpTests {
    private func saved(_ build: (inout SessionState) -> Void) throws -> Data {
        var state = SessionState()
        build(&state)
        return try StateCodec.encode(state)
    }

    // A press goes where a click on the newest notification would.
    @Test func goesToTheNewestWaitingSession() throws {
        let data = try saved {
            _ = $0.newNotification(sessionID: "older", now: 1)
            _ = $0.newNotification(sessionID: "newest", now: 3)
            _ = $0.newNotification(sessionID: "middle", now: 2)
        }
        #expect(
            WaitingJump.plan(residentRunning: true, savedState: data)
                == .jump(sessionID: "newest"))
    }

    // A session the user has already dealt with is not waiting, however recent.
    @Test func aSessionWithNothingOnScreenIsNotATarget() throws {
        let data = try saved {
            _ = $0.newNotification(sessionID: "waiting", now: 1)
            $0.anchor(sessionID: "seen", tabID: "TAB-2", now: 5)
        }
        #expect(
            WaitingJump.plan(residentRunning: true, savedState: data)
                == .jump(sessionID: "waiting"))
    }

    // The caller's cue to fall back to something of its own.
    @Test func nothingWaitingIsItsOwnAnswer() throws {
        let data = try saved { $0.anchor(sessionID: "seen", tabID: "TAB-1", now: 1) }
        #expect(WaitingJump.plan(residentRunning: true, savedState: data) == .nothingWaiting)
        // A fresh install has no saved bookkeeping at all.
        #expect(WaitingJump.plan(residentRunning: true, savedState: nil) == .nothingWaiting)
        // Nor does a file that does not decode.
        #expect(
            WaitingJump.plan(residentRunning: true, savedState: Data("{".utf8)) == .nothingWaiting)
    }

    // Saved bookkeeping outlives the agent; with nobody to act on it, no jump.
    @Test func noAgentMeansNoJumpEvenWithSomethingWaiting() throws {
        let data = try saved { _ = $0.newNotification(sessionID: "waiting", now: 1) }
        #expect(WaitingJump.plan(residentRunning: false, savedState: data) == .notRunning)
    }
}
