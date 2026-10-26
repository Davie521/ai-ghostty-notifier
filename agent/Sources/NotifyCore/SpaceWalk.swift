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
public enum SpaceWalk {
    public enum Outcome: Equatable, Sendable {
        case arrived(presses: Int, strayRetries: Int)
        case stopped(String)
    }

    /// How a trip there, and back if it gave up part-way, ended.
    public enum TripOutcome: Equatable, Sendable {
        case arrived(
            display: String, direction: SpaceHop.Direction, presses: Int, strayRetries: Int)
        case alreadyShowing
        case failed(String)
    }

    /// How long one press is given to change a display's Space.
    public static let pressTimeout = 1.5
    /// The topology reports the new Space while the slide is still running.
    public static let settleAfterPress = 0.15
    /// Presses that switched the wrong display, undone and tried again.
    public static let maxStrayRetries = 2
    /// The longest a walk back may take, after a trip that gave up.
    public static let maxWalkBackSeconds = 8.0
    /// What undoing a stray press may take: its press, its wait, and the
    /// pointer's move before it.
    static let undoSeconds = pressTimeout + settleAfterPress + 0.5

    /// Goes to `space` and, should the trip give up part-way, back to where
    /// the display was: the focus that follows a failed trip brings the window
    /// to the Space in view, and that should be the one the user was on, not
    /// one they passed on the way. `deadline` bounds the trip; `hardDeadline`
    /// bounds the walk back as well, for a caller that will be ended then.
    @MainActor
    public static func travel(
        to space: UInt64, deadline: Date, hardDeadline: Date = .distantFuture,
        driver: some SpaceWalkDriver
    ) async -> TripOutcome {
        guard let topology = driver.topology() else { return .failed("no Space topology") }
        let route = SpaceRoute.to(space, in: topology)
        guard case .hop(let first) = route else {
            return route == .showing ? .alreadyShowing : .failed("Space \(space) is on no display")
        }
        let start = topology.current(on: first.display)
        switch await walk(to: space, deadline: deadline, driver: driver) {
        case .arrived(let presses, let strayRetries):
            return .arrived(
                display: first.display, direction: first.direction, presses: presses,
                strayRetries: strayRetries)
        case .stopped(let why):
            guard let start, driver.topology()?.current(on: first.display) != start else {
                return .failed(why)
            }
            // A press on the way back may land on the other display too, and
            // its undo waits as long as the press did; both must fit.
            let back = min(
                driver.now().addingTimeInterval(maxWalkBackSeconds),
                hardDeadline.addingTimeInterval(-undoSeconds))
            switch await walk(to: start, deadline: back, driver: driver) {
            case .arrived: return .failed("\(why); went back")
            case .stopped(let backWhy): return .failed("\(why); could not go back: \(backWhy)")
            }
        }
    }

    /// One walk to `space`. No press starts unless its wait fits before
    /// `deadline`.
    @MainActor
    public static func walk(
        to space: UInt64, deadline: Date, driver: some SpaceWalkDriver
    ) async -> Outcome {
        guard var topology = driver.topology() else { return .stopped("no Space topology") }
        var route = SpaceRoute.to(space, in: topology)
        var presses = 0
        var strayRetries = 0
        while case .hop(let hop) = route {
            guard driver.now().addingTimeInterval(pressTimeout) < deadline else {
                return .stopped("out of time after \(presses) presses")
            }
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
                        return .stopped(
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
