import Testing

@testable import NotifyCore

@Suite struct TabJumpTests {
    let tab = "tab-c58859400"
    let other = "tab-c53c4c800"
    let window = "tab-group-c579d4be0"
    let hiddenA = OrderedWindow(number: 221_248, spaces: [8])
    let hiddenB = OrderedWindow(number: 150_542, spaces: [5])

    /// A jump up to its first focus: located, surveyed, placed.
    private func located(_ place: WindowPlace) -> (TabJump, TabJump.Step) {
        var jump = TabJump(requested: tab)
        #expect(jump.start == .locate)
        #expect(jump.observe(probe: .found(window: window)) == .survey(window: window))
        #expect(jump.window == window)
        let step = jump.observe(place: place)
        return (jump, step)
    }

    @Test func startsByLocating() {
        #expect(TabJump(requested: tab).start == .locate)
    }

    @Test func aTabNoWindowHasStops() {
        var jump = TabJump(requested: tab)
        #expect(jump.observe(probe: .notFound) == .stop(.notFound))
    }

    /// No answer from the lookup is not "not there": the focus command is
    /// sent as before lookups existed, and answers for itself.
    @Test func anUnansweredLookupFocusesAnyway() {
        var jump = TabJump(requested: tab)
        #expect(jump.observe(probe: .unknown) == .focus)
        #expect(jump.hops == 0)
    }

    @Test func aWindowInViewIsFocusedWithoutTravel() {
        var (jump, step) = located(.showing)
        #expect(step == .focus)
        #expect(jump.hops == 0)
        #expect(jump.observe(focusResult: tab) == .stop(.verified(reads: 0, focusAttempts: 1)))
    }

    @Test func aWindowTheSurveyCannotPlaceIsFocusedAnyway() {
        let (jump, step) = located(.unknown)
        #expect(step == .focus)
        #expect(jump.hops == 0)
    }

    /// Issue #63: the window is on a hidden Space. The jump travels there and,
    /// once the window is confirmed in view, focuses.
    @Test func aHiddenWindowIsTravelledToBeforeTheFocus() {
        var (jump, step) = located(.hidden(candidates: [hiddenA]))
        #expect(step == .hop(hiddenA))
        #expect(jump.hops == 1)
        #expect(jump.observe(hopResult: .arrived(confirmed: true)) == .focus)
        #expect(jump.lastHop == .arrived(confirmed: true))
        #expect(jump.observe(focusResult: tab) == .stop(.verified(reads: 0, focusAttempts: 1)))
    }

    /// Travel that could not happen — no Accessibility permission, the
    /// shortcut switched off — falls through to the focus the jump always did.
    @Test func aFailedTripStillFocuses() {
        var (jump, step) = located(.hidden(candidates: [hiddenA, hiddenB]))
        #expect(step == .hop(hiddenA))
        #expect(jump.observe(hopResult: .failed(reason: "accessibility not granted")) == .focus)
        #expect(jump.hops == 1)
    }

    /// Arrived, but the window there was another of Ghostty's: one more trip,
    /// to the next candidate.
    @Test func anUnconfirmedArrivalTriesTheNextCandidateOnce() {
        var (jump, step) = located(.hidden(candidates: [hiddenA, hiddenB]))
        #expect(step == .hop(hiddenA))
        #expect(jump.observe(hopResult: .arrived(confirmed: false)) == .hop(hiddenB))
        #expect(jump.hops == 2)
        #expect(jump.observe(hopResult: .arrived(confirmed: false)) == .focus)
        #expect(jump.hops == TabJump.maxHops)
    }

    @Test func anUnconfirmedArrivalWithNoOtherCandidateFocuses() {
        var (jump, step) = located(.hidden(candidates: [hiddenA]))
        #expect(step == .hop(hiddenA))
        #expect(jump.observe(hopResult: .arrived(confirmed: false)) == .focus)
    }

    @Test func noCandidatesMeansNoTravel() {
        let (jump, step) = located(.hidden(candidates: []))
        #expect(step == .focus)
        #expect(jump.hops == 0)
    }

    @Test func focusThatFindsNoTabStops() {
        var jump = TabJump(requested: tab)
        _ = jump.observe(probe: .unknown)
        #expect(jump.observe(focusResult: nil) == .stop(.notFound))
    }

    /// The 2026-09-22 sample: the read raced the focus and named the tab the
    /// user was on; the selection had in fact moved.
    @Test func mismatchEarnsOneSettleReadWhichCanVerify() {
        var (jump, _) = located(.showing)
        #expect(jump.observe(focusResult: other) == .verify(after: TabJump.settleSeconds))
        #expect(jump.observe(selected: tab) == .stop(.verified(reads: 1, focusAttempts: 1)))
    }

    /// The selection really did not move: one more focus, then its own read.
    @Test func persistentMismatchGetsASecondFocusThenGivesUp() {
        var (jump, _) = located(.showing)
        #expect(jump.observe(focusResult: other) == .verify(after: TabJump.settleSeconds))
        #expect(jump.observe(selected: other) == .focus)
        #expect(jump.observe(focusResult: other) == .verify(after: TabJump.settleSeconds))
        #expect(
            jump.observe(selected: other)
                == .stop(.unverified(selected: other, focusAttempts: 2)))
    }

    @Test func secondFocusCanVerifyDirectly() {
        var (jump, _) = located(.showing)
        _ = jump.observe(focusResult: other)
        _ = jump.observe(selected: other)
        #expect(jump.observe(focusResult: tab) == .stop(.verified(reads: 1, focusAttempts: 2)))
    }

    @Test func secondFocusCanVerifyOnItsSettleRead() {
        var (jump, _) = located(.showing)
        _ = jump.observe(focusResult: other)
        _ = jump.observe(selected: other)
        _ = jump.observe(focusResult: other)
        #expect(jump.observe(selected: tab) == .stop(.verified(reads: 2, focusAttempts: 2)))
    }

    @Test func anUnknownSelectionAfterTheLastFocusIsReportedAsSuch() {
        var (jump, _) = located(.showing)
        _ = jump.observe(focusResult: other)
        _ = jump.observe(selected: nil)
        _ = jump.observe(focusResult: other)
        #expect(jump.observe(selected: nil) == .stop(.unverified(selected: nil, focusAttempts: 2)))
    }

    /// Whatever Ghostty, the window server and the trips answer, a jump ends
    /// within a fixed number of steps.
    @Test(
        arguments: [nil, "tab-c53c4c800", "tab-zzz"] as [String?],
        [
            WindowPlace.showing, .unknown,
            .hidden(candidates: [
                OrderedWindow(number: 1, spaces: [8]), OrderedWindow(number: 2, spaces: [5]),
                OrderedWindow(number: 3, spaces: [4]),
            ]),
        ])
    func everyPathIsBounded(answer: String?, place: WindowPlace) {
        for hopResult in [
            TabJump.HopResult.arrived(confirmed: true), .arrived(confirmed: false),
            .failed(reason: "x"),
        ] {
            var jump = TabJump(requested: tab)
            var step = jump.start
            var steps = 0
            while true {
                steps += 1
                #expect(steps <= 12, "jump did not stop")
                if steps > 12 { break }
                switch step {
                case .locate: step = jump.observe(probe: .found(window: window))
                case .survey: step = jump.observe(place: place)
                case .hop: step = jump.observe(hopResult: hopResult)
                case .focus: step = jump.observe(focusResult: answer)
                case .verify: step = jump.observe(selected: answer)
                case .stop: break
                }
                if case .stop = step { break }
            }
            #expect(steps <= 10)
            #expect(jump.focusAttempts <= TabJump.maxFocusAttempts)
            #expect(jump.hops <= TabJump.maxHops)
        }
    }
}
