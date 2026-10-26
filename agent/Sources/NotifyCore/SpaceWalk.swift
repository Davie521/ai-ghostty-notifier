import Foundation

/// What a walk between Spaces needs from the window server and the keyboard,
/// so the walk itself can be tested without either.
@MainActor
public protocol SpaceWalkDriver {
    /// Each display's Spaces and the one it shows; nil when unanswered.
    func topology() -> SpaceTopology?
    /// Presses the "move a space" shortcut towards `direction` with the
    /// pointer on `display`. False when there is nothing to press: the
    /// shortcut is switched off, or the display is gone.
    func press(_ direction: SpaceHop.Direction, on display: String) async -> Bool
    /// The topology once `done` holds for it, or nil when it has not within
    /// `timeout` seconds.
    func poll(within timeout: Double, until done: (SpaceTopology) -> Bool) async -> SpaceTopology?
    func now() -> Date
    func pause(_ seconds: Double) async
    /// True once the jump is being given up: the app is quitting, or the work
    /// was cancelled. A walk then starts no press onward; it still undoes a
    /// press that landed on the wrong display, and still walks back, because
    /// both put the desktops back as they were.
    func stopRequested() -> Bool
    /// When the process will be ended, or `distantFuture`. Read before every
    /// press, because a signal can bring it forward in the middle of a walk.
    func hardDeadline() -> Date
}

extension SpaceTopology {
    /// The Space `display` shows, if the topology has the display.
    public func current(on display: String) -> UInt64? {
        displays.first { $0.identifier == display }?.current
    }
}

/// Walks a display to a Space with the user's own "move left/right a space"
/// shortcut, one checked press at a time.
///
/// Each press is checked against the topology before the next, and the route
/// recomputed, so a Mission Control that rearranges Spaces by recent use
/// cannot send the walk the wrong way, and a press that changes nothing ends
/// it. A press can land on another display — the shortcut acts on the display
/// under the pointer, and the user may move the mouse at that moment — so a
/// press that switches a display the walk is not for is undone, the undo
/// checked, and the press tried again, twice at most. A walk that cannot put
/// such a display back stops pressing at once.
///
/// A trip that gives up part-way walks back to where it started, and no press
/// onward starts unless there would still be time to walk back over every
/// Space passed so far before the process is ended. Wherever a trip stops —
/// given up, out of time, or because the app is quitting — the desktops end up
/// as they were or where the user asked to go, never somewhere in between.
public enum SpaceWalk {
    public enum Outcome: Equatable, Sendable {
        case arrived(presses: Int, strayRetries: Int)
        case stopped(String)
        /// A press landed on another display and the undo did not take: no
        /// more presses of any kind, not even a walk back.
        case stranded(String)
    }

    /// How a trip there, and back if it gave up part-way, ended.
    public enum TripOutcome: Equatable, Sendable {
        case arrived(
            display: String, from: UInt64, direction: SpaceHop.Direction, presses: Int,
            strayRetries: Int)
        case alreadyShowing
        /// The trip did not get there, and the desktops are as they were.
        case failed(String)
        /// The trip did not get there, and could not put the desktops back:
        /// a display is left on a Space the user never chose.
        case stranded(String)
    }

    /// Which way a walk goes: onward to the window's Space, or back to where
    /// the trip started. Only a walk onward is cut short when the jump is
    /// given up.
    enum Leg {
        case onward
        case back
    }

    /// How long one press is given to change a display's Space.
    public static let pressTimeout = 1.5
    /// The topology reports the new Space while the slide is still running.
    public static let settleAfterPress = 0.15
    /// Presses that switched the wrong display, undone and tried again.
    public static let maxStrayRetries = 2
    /// The longest the driver spends getting the pointer onto a display
    /// before a press.
    public static let parkSeconds = 0.3
    /// What one press may take from start to settled: the pointer's move, the
    /// wait for the Space to change, and the settle after it. A step of a
    /// walk back, and the undo of a stray press, are one each.
    static let stepSeconds = parkSeconds + pressTimeout + settleAfterPress
    static let undoSeconds = stepSeconds

    /// Goes to `space` and, should the trip give up part-way, back to where
    /// the display was: the focus that follows a failed trip brings the window
    /// to the Space in view, and that should be the one the user was on, not
    /// one they passed on the way. `deadline` bounds the trip onward.
    @MainActor
    public static func travel(
        to space: UInt64, deadline: Date, driver: some SpaceWalkDriver
    ) async -> TripOutcome {
        guard let topology = driver.topology() else { return .failed("no Space topology") }
        let route = SpaceRoute.to(space, in: topology)
        guard case .hop(let first) = route else {
            return route == .showing ? .alreadyShowing : .failed("Space \(space) is on no display")
        }
        guard let start = topology.current(on: first.display) else {
            return .failed("display \(first.display.prefix(8)) shows no Space")
        }
        switch await walk(to: space, deadline: deadline, leg: .onward, driver: driver) {
        case .arrived(let presses, let strayRetries):
            return .arrived(
                display: first.display, from: start, direction: first.direction, presses: presses,
                strayRetries: strayRetries)
        case .stranded(let why):
            return .stranded(why)
        case .stopped(let why):
            guard driver.topology()?.current(on: first.display) != start else {
                return .failed(why)
            }
            switch await goBack(to: SpaceSpot(display: first.display, space: start), driver: driver)
            {
            case .arrived: return .failed("\(why); went back")
            case .stopped(let backWhy), .stranded(let backWhy):
                return .stranded("\(why); could not go back: \(backWhy)")
            }
        }
    }

    /// Walks `spot.display` back to `spot.space`: the walk back after a trip
    /// that gave up, and the putting back of a trip that arrived at the wrong
    /// window. It is allowed a step's time for every Space between, an undo on
    /// top, and two steps for each press it may retry after one that landed
    /// on another display — that press and its undo bring it no nearer. The
    /// process's end bounds it as it bounds every press.
    @MainActor
    public static func goBack(to spot: SpaceSpot, driver: some SpaceWalkDriver) async -> Outcome {
        guard let topology = driver.topology() else { return .stopped("no Space topology") }
        let steps: Int
        switch SpaceRoute.to(spot.space, in: topology) {
        case .showing: return .arrived(presses: 0, strayRetries: 0)
        case .unreachable: return .stopped("Space \(spot.space) is out of reach")
        case .hop(let hop): steps = hop.steps
        }
        let allowance = walkBackSeconds(steps: steps + 2 * maxStrayRetries)
        return await walk(
            to: spot.space, deadline: driver.now().addingTimeInterval(allowance), leg: .back,
            driver: driver)
    }

    /// What walking back over `steps` Spaces is sure to need: a step for each,
    /// and an undo on top should a press land on another display. Every press
    /// onward keeps this much clear of the process's end, and so does every
    /// lookup made while a trip has a display moved.
    static func walkBackSeconds(steps: Int) -> Double {
        undoSeconds + Double(steps) * stepSeconds
    }

    /// What putting these displays back is sure to need. A Space that is on no
    /// display any more cannot be gone back to however long it is given, and
    /// counts for nothing.
    public static func putBackSeconds(_ spots: [SpaceSpot], in topology: SpaceTopology)
        -> Double
    {
        spots.reduce(0) { total, spot in
            guard case .hop(let hop) = SpaceRoute.to(spot.space, in: topology) else {
                return total
            }
            return total + walkBackSeconds(steps: hop.steps)
        }
    }

    /// How long a lookup may take at `now` and still leave the time to put
    /// these displays back before `hardDeadline`; nil when the process has no
    /// end in sight. With no topology to measure the way back by, none.
    public static func timeToLook(
        puttingBack spots: [SpaceSpot], now: Date, hardDeadline: Date,
        topology: SpaceTopology?
    ) -> Double? {
        guard hardDeadline != .distantFuture else { return nil }
        guard let topology else { return 0 }
        return max(0, hardDeadline.timeIntervalSince(now) - putBackSeconds(spots, in: topology))
    }

    /// One walk to `space`.
    @MainActor
    static func walk(
        to space: UInt64, deadline: Date, leg: Leg, driver: some SpaceWalkDriver
    ) async -> Outcome {
        guard var topology = driver.topology() else { return .stopped("no Space topology") }
        var route = SpaceRoute.to(space, in: topology)
        var presses = 0
        var strayRetries = 0
        while case .hop(let hop) = route {
            if leg == .onward, driver.stopRequested() {
                return .stopped("stopping after \(presses) presses")
            }
            // Room for this press, and for putting right whatever it may leave
            // before the process is ended: an undo, should it land on another
            // display, and on the way onward the walk back over every Space
            // passed by then.
            let done = driver.now().addingTimeInterval(parkSeconds + pressTimeout)
            let toPutRight = walkBackSeconds(steps: leg == .onward ? presses + 1 : 0)
            guard done < deadline, done.addingTimeInterval(toPutRight) < driver.hardDeadline()
            else { return .stopped("out of time after \(presses) presses") }
            guard presses < SpaceRoute.maxSteps else {
                return .stopped("\(presses) presses did not reach Space \(space)")
            }
            let before = topology
            guard await driver.press(hop.direction, on: hop.display) else {
                return .stopped("the move-a-space shortcut is switched off, or the display is gone")
            }
            guard
                let after = await driver.poll(
                    within: pressTimeout, until: { !$0.changedDisplays(since: before).isEmpty })
            else { return .stopped("press \(presses + 1) did not switch the Space") }
            let changed = after.changedDisplays(since: before)
            if changed.contains(hop.display) { presses += 1 }
            let strays = changed.filter { $0 != hop.display }
            if !strays.isEmpty {
                for stray in strays {
                    guard let original = before.current(on: stray),
                        await undo(stray, backTo: original, pressed: hop.direction, driver: driver)
                    else {
                        return .stranded(
                            "the shortcut switched display \(stray.prefix(8)) and it could not be put back"
                        )
                    }
                }
                guard strayRetries < maxStrayRetries else {
                    return .stopped(
                        "the shortcut switched display \(strays[0].prefix(8)), not "
                            + "\(hop.display.prefix(8)), \(strayRetries + 1) times")
                }
                strayRetries += 1
                topology = driver.topology() ?? before
                route = SpaceRoute.to(space, in: topology)
                continue
            }
            await driver.pause(settleAfterPress)
            topology = driver.topology() ?? after
            route = SpaceRoute.to(space, in: topology)
        }
        guard route == .showing else { return .stopped("Space \(space) left its display") }
        return .arrived(presses: presses, strayRetries: strayRetries)
    }

    /// One press the other way on `display`; true once it shows `original`.
    @MainActor
    private static func undo(
        _ display: String, backTo original: UInt64, pressed direction: SpaceHop.Direction,
        driver: some SpaceWalkDriver
    ) async -> Bool {
        let back: SpaceHop.Direction = direction == .left ? .right : .left
        guard await driver.press(back, on: display) else { return false }
        guard
            await driver.poll(within: pressTimeout, until: { $0.current(on: display) == original })
                != nil
        else { return false }
        await driver.pause(settleAfterPress)
        return true
    }
}
