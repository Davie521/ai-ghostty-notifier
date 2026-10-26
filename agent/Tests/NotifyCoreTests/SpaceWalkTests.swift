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
    var shortcutOn = true
    var clock = Date(timeIntervalSince1970: 1_000)
    let pressSeconds = 0.3
    /// The app quitting, or the work cancelled.
    var stopping = false
    /// When the process will be ended.
    var end = Date.distantFuture
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
        switch effects.isEmpty ? .aimed : effects.removeFirst() {
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
        if done(topology) { return topology }
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
        #expect(outcome == .arrived(display: "A", direction: .right, presses: 3, strayRetries: 0))
        #expect(fake.presses == ["right A", "right A", "right A"])
        #expect(fake.current("A") == 4)
        #expect(fake.current("B") == 10)
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
        #expect(outcome == .arrived(display: "A", direction: .right, presses: 2, strayRetries: 1))
        #expect(fake.presses == ["right A", "left B", "right A", "right A"])
        #expect(fake.current("B") == 10)
        #expect(fake.current("A") == 3)
    }

    /// An undo that did not take: no more presses, whatever is left to do.
    @Test func aDisplayThatCannotBePutBackStopsThePressing() async {
        let fake = spaces()
        fake.effects = [.stray("B"), .nothing]
        let outcome = await SpaceWalk.travel(to: 3, deadline: plenty(fake), driver: fake)
        guard case .failed(let why) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
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
        fake.end = start.addingTimeInterval(8)
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
        let fake = spaces()
        // One step out, then a dead press: the trip gives up 2.25 s in.
        fake.effects = [.aimed, .nothing, .stray("B"), .nothing]
        fake.afterPress = { fake, count in
            // During the dead press's wait, the end comes forward to 1.6 s
            // past the moment the walk back begins.
            if count == 2 { fake.end = fake.clock.addingTimeInterval(1.5 + 1.6) }
        }
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(fake.clock <= fake.end)
    }

    /// A step out, then a press on the other display whose undo does not
    /// take: the trip stops pressing there and then, walk back included.
    @Test func aDisplayThatCannotBePutBackStopsEvenTheWalkBack() async {
        let fake = spaces()
        fake.effects = [.aimed, .stray("B"), .nothing]
        let outcome = await SpaceWalk.travel(to: 6, deadline: plenty(fake), driver: fake)
        guard case .failed(let why) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
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
}
