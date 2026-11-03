import Foundation

/// What a walk between Spaces needs from the window server and the keyboard,
/// so the walk itself can be tested without either.
@MainActor
public protocol SpaceWalkDriver {
    /// Each display's Spaces and the one it shows; nil when unanswered.
    func topology() -> SpaceTopology?
    /// Whether the "move a space" shortcut towards `direction` is switched on.
    func hasShortcut(_ direction: SpaceHop.Direction) -> Bool
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
    /// Asks for `window` to be brought forward with its app, the way window
    /// switchers do; macOS answers by showing the window's Space. False when
    /// nothing was asked: the window could not be found to ask for, or this
    /// way is switched off. Within `SpaceWalk.raiseSeconds`.
    func raise(_ window: UInt32) async -> Bool
    /// The Spaces `window` is on now; nil when unanswered.
    func spaces(of window: UInt32) -> [UInt64]?
}

extension SpaceTopology {
    /// The Space `display` shows, if the topology has the display.
    public func current(on display: String) -> UInt64? {
        displays.first { $0.identifier == display }?.current
    }
}

/// Takes a display to a Space: straight there when it can, otherwise by
/// walking with the user's own "move left/right a space" shortcut, one checked
/// press at a time.
///
/// A walk shows every Space between on the way, each for as long as its press
/// takes to settle. With Ghostty windows on more than one Space — and Mission
/// Control's rearranging by recent use keeps those Spaces next to each other —
/// the Space passed is often the one with Ghostty's other window, and the jump
/// looks as if it went to the wrong window first. So a trip given the window
/// first asks for that window to be brought forward, as window switchers do:
/// macOS then shows its Space in one slide, with nothing in between. Only when
/// no display has switched by `switchSeconds` does the walk below take over;
/// a display the request did switch elsewhere is walked back first.
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
/// Space passed so far before the process is ended, presses on the way back
/// that land on another display included. Wherever a trip stops — given up,
/// out of time, or because the app is quitting — the desktops end up as they
/// were or where the user asked to go, never somewhere in between.
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
        /// Switched straight there: the window was brought forward and macOS
        /// showed its Space, with no Space between on the way.
        case switched(display: String, from: UInt64)
        /// The window came to a Space in view as it was brought forward, and
        /// no display switched: there is nowhere left to go.
        case broughtOver
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
    /// After the last press, before the window is focused: ordered front while
    /// still sliding in, it is the off-screen window of issue #63 again.
    public static let settleOnArrival = 0.25
    /// What one press may take from start to settled: the pointer's move, the
    /// wait for the Space to change, and the settle after it. A step of a
    /// walk back, and the undo of a stray press, are one each.
    static let stepSeconds = parkSeconds + pressTimeout + settleAfterPress
    static let undoSeconds = stepSeconds
    /// How long a window brought forward is given to bring its Space into
    /// view before the walk takes over. Measured on macOS 27: 0.40 to 0.52
    /// seconds from the request to the window server reporting the new Space.
    public static let switchSeconds = 1.0
    /// The longest the request itself may take, the search for the window
    /// included: the driver keeps it within this.
    public static let raiseSeconds = 1.0

    /// Goes to `space` and, should the trip give up part-way, back to where
    /// the display was: the focus that follows a failed trip brings the window
    /// to the Space in view, and that should be the one the user was on, not
    /// one they passed on the way. `deadline` bounds the trip onward.
    /// `window`, the window on `space` the trip is for, lets it switch straight
    /// there; without it the trip walks.
    @MainActor
    public static func travel(
        to space: UInt64, window: UInt32? = nil, deadline: Date, driver: some SpaceWalkDriver
    ) async -> TripOutcome {
        guard let topology = driver.topology() else { return .failed("no Space topology") }
        let route = SpaceRoute.to(space, in: topology)
        guard case .hop(let first) = route else {
            return route == .showing ? .alreadyShowing : .failed("Space \(space) is on no display")
        }
        guard let start = topology.current(on: first.display) else {
            return .failed("display \(first.display.prefix(8)) shows no Space")
        }
        // A trip needs both: one shortcut to go, the other to come back, or to
        // undo a press that landed on another display.
        // A switch straight there needs them too: the way back from a window
        // that turns out not to be the one, or from a display switched by
        // mistake, is a walk.
        guard driver.hasShortcut(.left), driver.hasShortcut(.right) else {
            return .failed("a move-a-space shortcut is switched off")
        }
        if let window {
            switch await switchStraight(
                to: space, window: window, hop: first, from: topology, deadline: deadline,
                driver: driver)
            {
            case .arrived:
                await driver.pause(settleOnArrival)
                return .switched(display: first.display, from: start)
            case .broughtOver: return .broughtOver
            case .stranded(let why): return .stranded(why)
            case .walk: break
            }
        }
        switch await walk(to: space, deadline: deadline, leg: .onward, driver: driver) {
        case .arrived(let presses, let strayRetries):
            await driver.pause(settleOnArrival)
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

    /// How a switch straight to a window's Space ended.
    enum Straight: Equatable {
        case arrived
        case broughtOver
        /// Nothing came of it, and the desktops are as they were: walk.
        case walk
        /// A display it switched elsewhere could not be put back.
        case stranded(String)
    }

    /// Brings `window` forward and waits for its Space to show on
    /// `hop.display`. A display the request switched anywhere else is walked
    /// back before the walk is left to it, so the walk starts from where the
    /// user was. No request is made unless there would still be time after
    /// the wait to walk back from the window's Space before the process is
    /// ended: a trip that arrives may turn out to have arrived at the wrong
    /// window, and that is walked back.
    @MainActor
    static func switchStraight(
        to space: UInt64, window: UInt32, hop: SpaceHop, from before: SpaceTopology,
        deadline: Date, driver: some SpaceWalkDriver
    ) async -> Straight {
        guard !driver.stopRequested() else { return .walk }
        let done = driver.now().addingTimeInterval(raiseSeconds + switchSeconds + settleAfterPress)
        let toPutRight = settleOnArrival + walkBackSeconds(steps: hop.steps)
        guard done < deadline, done.addingTimeInterval(toPutRight) < driver.hardDeadline()
        else { return .walk }
        guard await driver.raise(window) else { return .walk }
        guard
            let after = await driver.poll(
                within: switchSeconds, until: { !$0.changedDisplays(since: before).isEmpty })
        else {
            // No display switched. The window may have come over instead,
            // which is what the walk is there to avoid; it is in view now, and
            // there is nowhere left to go.
            if let spaces = driver.spaces(of: window), let now = driver.topology(),
                now.shows(anyOf: spaces)
            {
                return .broughtOver
            }
            return .walk
        }
        let arrived = after.current(on: hop.display) == space
        for display in after.changedDisplays(since: before)
        where !(arrived && display == hop.display) {
            guard let original = before.current(on: display) else { continue }
            guard
                case .arrived = await goBack(
                    to: SpaceSpot(display: display, space: original), driver: driver)
            else {
                return .stranded(
                    "bringing the window forward switched display \(display.prefix(8)) "
                        + "and it could not be put back")
            }
        }
        guard arrived else { return .walk }
        // The window server reports the new Space while the slide is still
        // running, as it does for a press.
        await driver.pause(settleAfterPress)
        return .arrived
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
        let allowance = walkBackSeconds(steps: steps)
        return await walk(
            to: spot.space, deadline: driver.now().addingTimeInterval(allowance), leg: .back,
            driver: driver)
    }

    /// What a walk back over `steps` Spaces is given: a step for each, two for
    /// each press it may retry after one that landed on another display — that
    /// press and its undo bring it no nearer — and an undo on top. Every press
    /// onward keeps this much clear of the process's end, and so does every
    /// lookup made while a trip has a display moved.
    static func walkBackSeconds(steps: Int) -> Double {
        undoSeconds + Double(steps + 2 * maxStrayRetries) * stepSeconds
    }

    /// What putting these displays back is given. A Space that is on no
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
            // Room for this press and its settle, and for putting right
            // whatever it may leave before the process is ended: on the way
            // back an undo, should it land on another display; on the way
            // onward the pause on arrival, should it be the last, and the walk
            // back over every Space passed by then — its undo of this press
            // included, should it land on another display.
            let done = driver.now().addingTimeInterval(stepSeconds)
            let toPutRight =
                leg == .onward
                ? settleOnArrival + walkBackSeconds(steps: presses + 1) : undoSeconds
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
