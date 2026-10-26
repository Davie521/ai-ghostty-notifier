import Foundation
import Testing

@testable import NotifyCore

/// A window server and a keyboard on paper. A press moves the display it is
/// aimed at one Space over, unless the next scripted effect says otherwise.
@MainActor
final class FakeSpaces: SpaceWalkDriver {
    enum Effect {
        case aimed
        /// The press lands on this display instead.
        case stray(String)
        /// The press changes nothing.
        case nothing
    }

    private(set) var displays: [SpaceTopology.Display]
    private(set) var presses: [String] = []
    var effects: [Effect] = []
    /// Taken before `effects` by presses to the left: a trip's walk back
    /// from the right, wherever the trip happened to stop.
    var leftEffects: [Effect] = []
    var shortcutOn = true
    var clock = Date(timeIntervalSince1970: 1_000)
    let pressSeconds = 0.3
    /// The app quitting, or the work cancelled.
    var stopping = false
    /// When the process will be ended.
    var end = Date.distantFuture
    /// How long a press takes to show on the display.
    var switchSeconds = 0.0
    /// Called after each press with the number of presses so far: where a
    /// test makes the app quit or a signal bring the end forward.
    var afterPress: ((FakeSpaces, Int) -> Void)?

    init(_ displays: [SpaceTopology.Display]) { self.displays = displays }

    func current(_ display: String) -> UInt64? {
        displays.first { $0.identifier == display }?.current
    }

    func topology() -> SpaceTopology? { SpaceTopology(displays: displays) }

    func press(_ direction: SpaceHop.Direction, on display: String) async -> Bool {
        guard shortcutOn else { return false }
        presses.append("\(direction == .left ? "left" : "right") \(display)")
        clock += pressSeconds
        let effect: Effect
        if direction == .left, !leftEffects.isEmpty {
            effect = leftEffects.removeFirst()
        } else {
            effect = effects.isEmpty ? .aimed : effects.removeFirst()
        }
        switch effect {
        case .aimed: move(display, direction)
        case .stray(let other): move(other, direction)
        case .nothing: break
        }
        afterPress?(self, presses.count)
        return true
    }

    func poll(within timeout: Double, until done: (SpaceTopology) -> Bool) async
        -> SpaceTopology?
    {
        let topology = SpaceTopology(displays: displays)
        if done(topology), switchSeconds < timeout {
            clock += switchSeconds
            return topology
        }
        clock += timeout
        return nil
    }

    func now() -> Date { clock }
    func pause(_ seconds: Double) async { clock += seconds }
    func stopRequested() -> Bool { stopping }
    func hardDeadline() -> Date { end }

    private func move(_ display: String, _ direction: SpaceHop.Direction) {
        guard let index = displays.firstIndex(where: { $0.identifier == display }),
            let current = displays[index].current,
            let position = displays[index].spaces.firstIndex(of: current)
        else { return }
        let next = position + (direction == .right ? 1 : -1)
        guard displays[index].spaces.indices.contains(next) else { return }
        displays[index] = SpaceTopology.Display(
            identifier: display, spaces: displays[index].spaces,
            current: displays[index].spaces[next])
    }
}

@MainActor
@Suite struct SpaceWalkTests {
    /// Display A has six Spaces and shows the first; B has two.
    func spaces() -> FakeSpaces {
        FakeSpaces([
            SpaceTopology.Display(identifier: "A", spaces: [1, 2, 3, 4, 5, 6], current: 1),
            SpaceTopology.Display(identifier: "B", spaces: [10, 11], current: 10),
        ])
    }

    func plenty(_ fake: FakeSpaces) -> Date { fake.clock.addingTimeInterval(100) }

    @Test func aTripWalksToTheSpaceOnePressAtATime() async {
        let fake = spaces()
        let outcome = await SpaceWalk.travel(to: 4, deadline: plenty(fake), driver: fake)
        #expect(
            outcome
                == .arrived(display: "A", from: 1, direction: .right, presses: 3, strayRetries: 0))
        #expect(fake.presses == ["right A", "right A", "right A"])
        #expect(fake.current("A") == 4)
        #expect(fake.current("B") == 10)
    }

    /// The window is focused once the Space has stopped sliding in, not while
    /// it still is.
    @Test func aTripWaitsForTheSlideOnArrival() async {
        let fake = spaces()
        let start = fake.clock
        _ = await SpaceWalk.travel(to: 2, deadline: plenty(fake), driver: fake)
        let press = fake.pressSeconds + SpaceWalk.settleAfterPress
        // A `Date` this far from 2001 keeps time to a fraction of a microsecond.
        let elapsed = fake.clock.timeIntervalSince(start)
        #expect(abs(elapsed - (press + SpaceWalk.settleOnArrival)) < 1e-6, "\(elapsed)")
    }

    @Test func aSpaceInViewNeedsNoPress() async {
        let fake = spaces()
        #expect(
            await SpaceWalk.travel(to: 1, deadline: plenty(fake), driver: fake) == .alreadyShowing)
        #expect(fake.presses.isEmpty)
    }

    @Test func aSpaceNoDisplayHasFails() async {
        let fake = spaces()
        #expect(
            await SpaceWalk.travel(to: 99, deadline: plenty(fake), driver: fake)
                == .failed("Space 99 is on no display"))
        #expect(fake.presses.isEmpty)
    }

    /// The press landed on the other display: it is put back, checked, and
    /// the press tried again.
    @Test func aPressOnTheOtherDisplayIsUndoneAndTriedAgain() async {
        let fake = spaces()
        fake.effects = [.stray("B")]
        let outcome = await SpaceWalk.travel(to: 3, deadline: plenty(fake), driver: fake)
        #expect(
            outcome
                == .arrived(display: "A", from: 1, direction: .right, presses: 2, strayRetries: 1))
        #expect(fake.presses == ["right A", "left B", "right A", "right A"])
        #expect(fake.current("B") == 10)
        #expect(fake.current("A") == 3)
    }

    /// An undo that did not take: no more presses, whatever is left to do.
    @Test func aDisplayThatCannotBePutBackStopsThePressing() async {
        let fake = spaces()
        fake.effects = [.stray("B"), .nothing]
        let outcome = await SpaceWalk.travel(to: 3, deadline: plenty(fake), driver: fake)
        guard case .stranded(let why) = outcome else {
            Issue.record("expected a stranded trip, got \(outcome)")
            return
        }
        #expect(why.contains("could not be put back"))
        #expect(fake.presses == ["right A", "left B"])
    }

    @Test func pressesOnTheOtherDisplayAreTriedAgainTwiceAtMost() async {
        let fake = spaces()
        fake.effects = [.stray("B"), .aimed, .stray("B"), .aimed, .stray("B"), .aimed]
        let outcome = await SpaceWalk.travel(to: 3, deadline: plenty(fake), driver: fake)
        guard case .failed(let why) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(why.contains("3 times"))
        #expect(fake.presses.count == 6)
        #expect(fake.current("B") == 10)
        #expect(fake.current("A") == 1)
    }

    @Test func aPressThatSwitchesNothingStopsTheTrip() async {
        let fake = spaces()
        fake.effects = [.nothing]
        let outcome = await SpaceWalk.travel(to: 3, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("press 1 did not switch the Space"))
        #expect(fake.presses == ["right A"])
    }

    /// Two Spaces along, the presses stop working: the display goes back to
    /// the Space it showed, so the focus that follows does not bring the
    /// window to a Space the user only passed through.
    @Test func aTripThatGivesUpPartWayGoesBack() async {
        let fake = spaces()
        fake.effects = [.aimed, .aimed, .nothing]
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("press 3 did not switch the Space; went back"))
        #expect(fake.presses == ["right A", "right A", "right A", "left A", "left A"])
        #expect(fake.current("A") == 1)
    }

    /// Time runs out part-way: the same walk back.
    @Test func aTripOutOfTimePartWayGoesBack() async {
        let fake = spaces()
        let outcome = await SpaceWalk.travel(
            to: 6, deadline: fake.clock.addingTimeInterval(2.5), driver: fake)
        guard case .failed(let why) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(why.hasPrefix("out of time after"))
        #expect(why.hasSuffix("went back"))
        #expect(fake.current("A") == 1)
    }

    /// No press starts unless its wait fits before the deadline.
    @Test func noPressStartsThatCouldNotFinishInTime() async {
        let fake = spaces()
        let outcome = await SpaceWalk.travel(
            to: 3, deadline: fake.clock.addingTimeInterval(1), driver: fake)
        #expect(outcome == .failed("out of time after 0 presses"))
        #expect(fake.presses.isEmpty)
    }

    /// No press onward starts unless there would be time, before the process
    /// is ended, to undo it and to walk back over it.
    @Test func noPressStartsWithoutTimeToPutItRight() async {
        let fake = spaces()
        fake.end = fake.clock.addingTimeInterval(4)
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("out of time after 0 presses"))
        #expect(fake.presses.isEmpty)
    }

    /// Close to the end, a trip goes as far as it can still come back from,
    /// and comes back in time.
    @Test func aTripNearTheEndGoesOnlyAsFarAsItCanComeBackFrom() async {
        let fake = spaces()
        let start = fake.clock
        fake.end = start.addingTimeInterval(20)
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        guard case .failed(let why) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(why.hasPrefix("out of time after"))
        #expect(why.hasSuffix("went back"))
        #expect(fake.current("A") == 1)
        #expect(fake.clock <= fake.end)
    }

    @Test func aShortcutSwitchedOffPressesNothing() async {
        let fake = spaces()
        fake.shortcutOn = false
        let outcome = await SpaceWalk.travel(to: 3, deadline: plenty(fake), driver: fake)
        #expect(
            outcome == .failed("the move-a-space shortcut is switched off, or the display is gone"))
        #expect(fake.current("A") == 1)
    }

    /// On the way back, close to the end — a signal brought it forward — a
    /// press that lands on the other display and an undo that waits in vain
    /// must both fit before it.
    @Test func aStrayPressOnTheWayBackStillEndsBeforeTheEnd() async {
        // B shows its second Space, so a press on the way back — leftward —
        // that lands on B does move it.
        let fake = FakeSpaces([
            SpaceTopology.Display(identifier: "A", spaces: [1, 2, 3, 4, 5, 6], current: 1),
            SpaceTopology.Display(identifier: "B", spaces: [10, 11], current: 11),
        ])
        // One step out, then a dead press: the trip gives up 2.25 s in.
        fake.effects = [.aimed, .nothing, .stray("B"), .nothing]
        fake.afterPress = { fake, count in
            // During the dead press's wait, the end comes forward to 2 s past
            // the moment the walk back begins: room for a press, not for the
            // undo a stray press would need on top.
            if count == 2 { fake.end = fake.clock.addingTimeInterval(1.5 + 2) }
        }
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        guard case .stranded = outcome else {
            Issue.record("expected a stranded trip, got \(outcome)")
            return
        }
        #expect(fake.clock <= fake.end)
        // Nothing was pressed on the way back: B was never touched.
        #expect(fake.current("B") == 11)
    }

    /// A step out, then a press on the other display whose undo does not
    /// take: the trip stops pressing there and then, walk back included.
    @Test func aDisplayThatCannotBePutBackStopsEvenTheWalkBack() async {
        let fake = spaces()
        fake.effects = [.aimed, .stray("B"), .nothing]
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        guard case .stranded(let why) = outcome else {
            Issue.record("expected a stranded trip, got \(outcome)")
            return
        }
        #expect(why.contains("could not be put back"))
        #expect(fake.presses == ["right A", "right A", "left B"])
    }

    /// Quitting before the trip has begun: not a single press.
    @Test func aJumpGivenUpBeforeItsTripPressesNothing() async {
        let fake = spaces()
        fake.stopping = true
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("stopping after 0 presses"))
        #expect(fake.presses.isEmpty)
    }

    /// Quitting two Spaces into a trip of five: no press onward after that,
    /// and the display walks back to where it was.
    @Test func aJumpGivenUpPartWayWalksBack() async {
        let fake = spaces()
        fake.afterPress = { fake, count in if count == 2 { fake.stopping = true } }
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("stopping after 2 presses; went back"))
        #expect(fake.presses == ["right A", "right A", "left A", "left A"])
        #expect(fake.current("A") == 1)
    }

    /// Quitting while the trip already walks back: the walk back is the
    /// putting right, and is not cut short.
    @Test func aJumpGivenUpOnItsWayBackStillGetsBack() async {
        let fake = spaces()
        fake.effects = [.aimed, .aimed, .nothing]
        fake.afterPress = { fake, count in if count == 4 { fake.stopping = true } }
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("press 3 did not switch the Space; went back"))
        #expect(fake.presses == ["right A", "right A", "right A", "left A", "left A"])
        #expect(fake.current("A") == 1)
    }

    /// Quitting right after a press that landed on the other display: that
    /// display is still put back, and nothing more is pressed onward.
    @Test func aJumpGivenUpAfterAStrayPressStillPutsTheDisplayBack() async {
        let fake = spaces()
        fake.effects = [.aimed, .stray("B")]
        fake.afterPress = { fake, count in if count == 2 { fake.stopping = true } }
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("stopping after 1 presses; went back"))
        #expect(fake.presses == ["right A", "right A", "left B", "left A"])
        #expect(fake.current("B") == 10)
        #expect(fake.current("A") == 1)
    }

    /// A press that takes its time — the pointer's move and nearly all of the
    /// wait — must still leave the time to walk back over it: the press and
    /// its settle, the pause on arrival, and a walk back over one Space with
    /// two presses on the other display undone on the way need 13.9 s, so
    /// 13.85 s before the end is too close to start.
    @Test func aSlowPressNearTheEndIsNotStartedWithoutTimeToComeBack() async {
        let fake = spaces()
        fake.switchSeconds = 1.49
        fake.end = fake.clock.addingTimeInterval(13.85)
        fake.afterPress = { fake, count in if count == 1 { fake.stopping = true } }
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("out of time after 0 presses"))
        #expect(fake.presses.isEmpty)
        #expect(fake.current("A") == 1)
    }

    /// With room to spare the same slow press is made, and walked back over.
    @Test func aSlowPressWithRoomToSpareIsWalkedBack() async {
        let fake = spaces()
        fake.switchSeconds = 1.49
        fake.end = fake.clock.addingTimeInterval(13.95)
        fake.afterPress = { fake, count in if count == 1 { fake.stopping = true } }
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("stopping after 1 presses; went back"))
        #expect(fake.current("A") == 1)
        #expect(fake.clock <= fake.end)
    }

    /// Five Spaces out, then a dead press, and every step back slow: the walk
    /// back is given the time its steps need, not a fixed allowance that runs
    /// out half-way.
    @Test func aLongTripIsWalkedBackAllTheWayEvenWhenEachStepIsSlow() async {
        let fake = FakeSpaces([
            SpaceTopology.Display(identifier: "A", spaces: Array(1...8), current: 1),
            SpaceTopology.Display(identifier: "B", spaces: [10, 11], current: 10),
        ])
        fake.effects = [.aimed, .aimed, .aimed, .aimed, .aimed, .nothing]
        fake.afterPress = { fake, count in if count == 6 { fake.switchSeconds = 1.49 } }
        let outcome = await SpaceWalk.travel(to: 8, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("press 6 did not switch the Space; went back"))
        #expect(fake.current("A") == 1)
    }

    /// Putting a display back that an earlier trip moved.
    @Test func goingBackWalksTheDisplayToWhereItWas() async {
        let fake = spaces()
        for _ in 0..<3 { _ = await fake.press(.right, on: "A") }
        #expect(fake.current("A") == 4)
        let outcome = await SpaceWalk.goBack(to: SpaceSpot(display: "A", space: 1), driver: fake)
        #expect(outcome == .arrived(presses: 3, strayRetries: 0))
        #expect(fake.current("A") == 1)
        #expect(
            await SpaceWalk.goBack(to: SpaceSpot(display: "A", space: 1), driver: fake)
                == .arrived(presses: 0, strayRetries: 0))
    }

    /// One Space back, with presses that take their time, and the first one
    /// landing on the other display: that press and its undo bring the walk no
    /// nearer, and are budgeted for.
    @Test func aWalkBackHasTimeForAPressThatLandsOnTheOtherDisplay() async {
        let fake = FakeSpaces([
            SpaceTopology.Display(identifier: "A", spaces: [1, 2, 3], current: 2),
            SpaceTopology.Display(identifier: "B", spaces: [10, 11], current: 11),
        ])
        fake.switchSeconds = 0.8
        fake.effects = [.stray("B")]
        let outcome = await SpaceWalk.goBack(to: SpaceSpot(display: "A", space: 1), driver: fake)
        #expect(outcome == .arrived(presses: 1, strayRetries: 1))
        #expect(fake.current("A") == 1)
        #expect(fake.current("B") == 11)
    }

    /// Every press as slow as it may be and still count, and a trip that stops
    /// because the end is near: its walk back must still have time for a
    /// press that lands on the other display, the undo, and the press again.
    @Test func aTripStoppedNearTheEndGetsBackDespiteAPressOnTheOtherDisplay() async {
        // B shows its second Space, so a press back — leftward — that lands
        // on B does move it.
        let fake = FakeSpaces([
            SpaceTopology.Display(identifier: "A", spaces: [1, 2, 3, 4, 5, 6], current: 1),
            SpaceTopology.Display(identifier: "B", spaces: [10, 11], current: 11),
        ])
        fake.switchSeconds = 1.45
        fake.end = fake.clock.addingTimeInterval(18)
        fake.leftEffects = [.stray("B")]
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("out of time after 2 presses; went back"))
        #expect(fake.current("A") == 1)
        #expect(fake.current("B") == 11)
        #expect(fake.clock <= fake.end)
    }

    /// The settle after a press and the pause on arrival count against the end
    /// like the press itself: a slow last press that would leave the way back
    /// short by them is not made.
    @Test func aSlowLastPressIsNotMadeWithoutTimeForItsSettleAndTheArrival() async {
        let fake = spaces()
        let start = fake.clock
        fake.switchSeconds = 1.45
        // The second press starts 1.9 s in.
        fake.end =
            start + 1.9 + SpaceWalk.stepSeconds + SpaceWalk.settleOnArrival
            + SpaceWalk.walkBackSeconds(steps: 2) - 0.05
        let outcome = await SpaceWalk.travel(to: 3, deadline: plenty(fake), driver: fake)
        #expect(outcome == .failed("out of time after 1 presses; went back"))
        #expect(fake.current("A") == 1)
    }

    func near(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    /// What a lookup made while a trip has a display moved must leave, for
    /// each display moved: a step for every Space back, two for each press
    /// that may land on the other display on the way, and an undo.
    @Test func puttingBackIsGivenAStepPerSpaceTwoPerRetryAndAnUndo() {
        let topology = SpaceTopology(displays: [
            SpaceTopology.Display(identifier: "A", spaces: [1, 2, 3, 4], current: 4),
            SpaceTopology.Display(identifier: "B", spaces: [10, 11], current: 11),
        ])
        let step = SpaceWalk.stepSeconds
        let undo = SpaceWalk.undoSeconds
        let retries = Double(2 * SpaceWalk.maxStrayRetries)
        let a = SpaceSpot(display: "A", space: 1)
        let b = SpaceSpot(display: "B", space: 10)
        #expect(near(SpaceWalk.putBackSeconds([a], in: topology), undo + (3 + retries) * step))
        #expect(
            near(
                SpaceWalk.putBackSeconds([a, b], in: topology),
                undo + (3 + retries) * step + undo + (1 + retries) * step))
        // Already back, and gone: neither needs any time.
        #expect(SpaceWalk.putBackSeconds([SpaceSpot(display: "B", space: 11)], in: topology) == 0)
        #expect(SpaceWalk.putBackSeconds([SpaceSpot(display: "A", space: 99)], in: topology) == 0)
    }

    @Test func aLookupGetsWhatIsLeftOnceTheWayBackIsSetAside() {
        let topology = SpaceTopology(displays: [
            SpaceTopology.Display(identifier: "A", spaces: [1, 2, 3, 4], current: 4)
        ])
        let now = Date(timeIntervalSince1970: 1_000)
        let spots = [SpaceSpot(display: "A", space: 1)]
        let back = SpaceWalk.putBackSeconds(spots, in: topology)
        #expect(
            near(
                SpaceWalk.timeToLook(
                    puttingBack: spots, now: now, hardDeadline: now + 20, topology: topology),
                20 - back))
        // Less than the way back: nothing, never less.
        #expect(
            SpaceWalk.timeToLook(
                puttingBack: spots, now: now, hardDeadline: now + back - 1, topology: topology)
                == 0)
        // No end in sight: no limit, topology or not.
        #expect(
            SpaceWalk.timeToLook(
                puttingBack: spots, now: now, hardDeadline: .distantFuture, topology: topology)
                == nil)
        #expect(
            SpaceWalk.timeToLook(
                puttingBack: spots, now: now, hardDeadline: .distantFuture, topology: nil) == nil)
        // An end, and no way to tell how long the way back is: no time to look.
        #expect(
            SpaceWalk.timeToLook(
                puttingBack: spots, now: now, hardDeadline: now + 60, topology: nil) == 0)
    }

    /// The trip and the lookups after it set aside the same way back: a trip
    /// that only just fitted before the end still leaves time to look whether
    /// it arrived at the window, instead of having to turn back at once.
    @Test func aTripThatOnlyJustFittedLeavesTimeToLookAfterIt() async {
        let fake = spaces()
        let start = fake.clock
        // The third press is the last that fits: it starts 0.9 s in.
        fake.end =
            start + 0.9 + SpaceWalk.stepSeconds + SpaceWalk.settleOnArrival
            + SpaceWalk.walkBackSeconds(steps: 3) + 0.05
        let outcome = await SpaceWalk.travel(to: 4, deadline: plenty(fake), driver: fake)
        #expect(
            outcome
                == .arrived(display: "A", from: 1, direction: .right, presses: 3, strayRetries: 0))
        let left = SpaceWalk.timeToLook(
            puttingBack: [SpaceSpot(display: "A", space: 1)], now: fake.clock,
            hardDeadline: fake.end, topology: fake.topology())
        #expect((left ?? 0) > 1)
    }
}
