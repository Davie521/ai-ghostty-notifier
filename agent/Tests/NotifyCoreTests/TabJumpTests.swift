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

    /// Issue #63: the window is on a hidden Space. The jump travels there,
    /// looks again with what Ghostty and the window server say now, and
    /// focuses once that look finds the window in view.
    @Test func aHiddenWindowIsTravelledToBeforeTheFocus() {
        var (jump, step) = located(.hidden(candidates: [hiddenA]))
        #expect(step == .hop(hiddenA))
        #expect(jump.hops == 1)
        #expect(jump.observe(hopResult: .arrived) == .locate)
        #expect(jump.lastHop == .arrived)
        #expect(jump.observe(probe: .found(window: window)) == .survey(window: window))
        #expect(jump.observe(place: .showing) == .focus)
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

    /// Arrived, but the fresh look still finds the window out of view — the
    /// Space held another of Ghostty's windows: one more trip, to a window
    /// not yet visited, and no more after that.
    @Test func anArrivalThatStillLeavesTheWindowHiddenTriesAnotherCandidateOnce() {
        var (jump, step) = located(.hidden(candidates: [hiddenA, hiddenB]))
        #expect(step == .hop(hiddenA))
        #expect(jump.observe(hopResult: .arrived) == .locate)
        _ = jump.observe(probe: .found(window: window))
        // The fresh survey lists the window just visited first; it is skipped.
        #expect(jump.observe(place: .hidden(candidates: [hiddenA, hiddenB])) == .hop(hiddenB))
        #expect(jump.hops == 2)
        #expect(jump.observe(hopResult: .arrived) == .locate)
        _ = jump.observe(probe: .found(window: window))
        #expect(jump.observe(place: .hidden(candidates: [hiddenA, hiddenB])) == .focus)
        #expect(jump.hops == TabJump.maxHops)
    }

    @Test func anArrivalThatStillLeavesTheWindowHiddenWithNoOtherCandidateFocuses() {
        var (jump, step) = located(.hidden(candidates: [hiddenA]))
        #expect(step == .hop(hiddenA))
        #expect(jump.observe(hopResult: .arrived) == .locate)
        _ = jump.observe(probe: .found(window: window))
        #expect(jump.observe(place: .hidden(candidates: [hiddenA])) == .focus)
        #expect(jump.hops == 1)
    }

    /// The tab closed during the trip: the fresh look says so.
    @Test func aTabThatClosedDuringTheTripStops() {
        var (jump, _) = located(.hidden(candidates: [hiddenA]))
        #expect(jump.observe(hopResult: .arrived) == .locate)
        #expect(jump.observe(probe: .notFound) == .stop(.notFound))
    }

    /// Lists that do not pair are read again, twice at most; then the jump
    /// focuses without travelling.
    @Test func anUnsettledSurveyIsReadAgainThenGivesWay() {
        var (jump, step) = located(.unsettled)
        #expect(step == .locate)
        #expect(jump.rereads == 1)
        _ = jump.observe(probe: .found(window: window))
        #expect(jump.observe(place: .unsettled) == .locate)
        _ = jump.observe(probe: .found(window: window))
        #expect(jump.observe(place: .unsettled) == .focus)
        #expect(jump.rereads == TabJump.maxRereads)
        #expect(jump.hops == 0)
    }

    /// A read again that pairs travels as usual.
    @Test func anUnsettledSurveyThatSettlesTravels() {
        var (jump, step) = located(.unsettled)
        #expect(step == .locate)
        _ = jump.observe(probe: .found(window: window))
        #expect(jump.observe(place: .hidden(candidates: [hiddenA])) == .hop(hiddenA))
    }

    /// Quitting: the jump stops where it stands, whatever was next — after a
    /// trip that gave up, that would have been the focus that pulls windows.
    @Test func anAbandonedJumpTakesNoFurtherStep() {
        var (jump, step) = located(.hidden(candidates: [hiddenA]))
        #expect(step == .hop(hiddenA))
        #expect(jump.observe(hopResult: .failed(reason: "stopping after 0 presses")) == .focus)
        #expect(jump.abandon() == .stop(.abandoned))
        #expect(TabJump(requested: tab).abandon() == .stop(.abandoned))
    }

    /// A trip that stopped part-way and could not get back: no focus, which
    /// would bring the window to wherever the desktops were left.
    @Test func aTripThatCouldNotGetBackEndsTheJumpWithoutAFocus() {
        var (jump, step) = located(.hidden(candidates: [hiddenA]))
        #expect(step == .hop(hiddenA))
        #expect(
            jump.observe(hopResult: .stranded(reason: "could not go back")) == .stop(.strandedTrip))
        #expect(jump.focusAttempts == 0)
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
            WindowPlace.showing, .unknown, .unsettled,
            .hidden(candidates: [
                OrderedWindow(number: 1, spaces: [8]), OrderedWindow(number: 2, spaces: [5]),
                OrderedWindow(number: 3, spaces: [4]),
            ]),
        ])
    func everyPathIsBounded(answer: String?, place: WindowPlace) {
        for hopResult in [TabJump.HopResult.arrived, .failed(reason: "x"), .stranded(reason: "y")] {
            var jump = TabJump(requested: tab)
            var step = jump.start
            var steps = 0
            while true {
                steps += 1
                #expect(steps <= 30, "jump did not stop")
                if steps > 30 { break }
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
            #expect(steps <= 20)
            #expect(jump.rereads <= TabJump.maxRereads)
            #expect(jump.focusAttempts <= TabJump.maxFocusAttempts)
            #expect(jump.hops <= TabJump.maxHops)
        }
    }
}
