import Testing

@testable import NotifyCore

@Suite struct TabJumpTests {
    let tab = "tab-c58859400"
    let other = "tab-c53c4c800"

    @Test func startsByFocusing() {
        #expect(TabJump(requested: tab).start == .focus)
    }

    @Test func focusThatReportsTheRequestedTabIsVerifiedAtOnce() {
        var jump = TabJump(requested: tab)
        #expect(jump.observe(focusResult: tab) == .stop(.verified(reads: 0, focusAttempts: 1)))
    }

    @Test func focusThatFindsNoTabStops() {
        var jump = TabJump(requested: tab)
        #expect(jump.observe(focusResult: nil) == .stop(.notFound))
    }

    /// The 2026-09-22 sample: the read raced the focus and named the tab the
    /// user was on; the selection had in fact moved.
    @Test func mismatchEarnsOneSettleReadWhichCanVerify() {
        var jump = TabJump(requested: tab)
        #expect(jump.observe(focusResult: other) == .verify(after: TabJump.settleSeconds))
        #expect(jump.observe(selected: tab) == .stop(.verified(reads: 1, focusAttempts: 1)))
    }

    /// The selection really did not move: one more focus, then its own read.
    @Test func persistentMismatchGetsASecondFocusThenGivesUp() {
        var jump = TabJump(requested: tab)
        #expect(jump.observe(focusResult: other) == .verify(after: TabJump.settleSeconds))
        #expect(jump.observe(selected: other) == .focus)
        #expect(jump.observe(focusResult: other) == .verify(after: TabJump.settleSeconds))
        #expect(
            jump.observe(selected: other)
                == .stop(.unverified(selected: other, focusAttempts: 2)))
    }

    @Test func secondFocusCanVerifyDirectly() {
        var jump = TabJump(requested: tab)
        _ = jump.observe(focusResult: other)
        _ = jump.observe(selected: other)
        #expect(jump.observe(focusResult: tab) == .stop(.verified(reads: 1, focusAttempts: 2)))
    }

    @Test func secondFocusCanVerifyOnItsSettleRead() {
        var jump = TabJump(requested: tab)
        _ = jump.observe(focusResult: other)
        _ = jump.observe(selected: other)
        _ = jump.observe(focusResult: other)
        #expect(jump.observe(selected: tab) == .stop(.verified(reads: 2, focusAttempts: 2)))
    }

    @Test func anUnknownSelectionAfterTheLastFocusIsReportedAsSuch() {
        var jump = TabJump(requested: tab)
        _ = jump.observe(focusResult: other)
        _ = jump.observe(selected: nil)
        _ = jump.observe(focusResult: other)
        #expect(jump.observe(selected: nil) == .stop(.unverified(selected: nil, focusAttempts: 2)))
    }

    /// Whatever Ghostty answers, a jump ends within a fixed number of steps.
    @Test(arguments: [nil, "tab-c53c4c800", "tab-zzz"] as [String?])
    func everyPathIsBounded(answer: String?) {
        var jump = TabJump(requested: tab)
        var step = jump.start
        var steps = 0
        while true {
            steps += 1
            #expect(steps <= 6, "jump did not stop")
            if steps > 6 { break }
            switch step {
            case .focus: step = jump.observe(focusResult: answer)
            case .verify: step = jump.observe(selected: answer)
            case .stop: break
            }
            if case .stop = step { break }
        }
        #expect(steps <= 5)
        #expect(jump.focusAttempts <= TabJump.maxFocusAttempts)
    }
}
