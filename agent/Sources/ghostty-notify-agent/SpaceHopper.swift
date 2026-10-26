import AppKit
import NotifyCore

/// Brings a window's Space into view the way the user would: by pressing
/// their "move left/right a space" shortcut, on the display that has the
/// Space, as many times as it takes.
///
/// Asking the window server to front the window, as the window switchers
/// do, fronted nothing on this machine (macOS 26.6.2) while Ghostty had a
/// window in view on the other display; the shortcut switched every time.
/// The shortcut acts on the display under the pointer — measured: with the
/// key window on one display and the pointer on the other, the pointer's
/// display switched — so the pointer is moved there right before every press
/// and put back after the trip; the press waits until the pointer is seen
/// there. A press can still land on the other display — once in nine live
/// runs it did — so a press that switches a display the trip is not for is
/// undone and tried again, twice at most. Every press is checked
/// against the topology before the next and the route recomputed, so a
/// Mission Control that rearranges Spaces by recent use cannot send the trip
/// the wrong way, and a press that changes nothing ends it.
@MainActor
enum SpaceHopper {
    struct Trip: Equatable, Sendable {
        let display: String
        let direction: SpaceHop.Direction
        let presses: Int
        /// Presses that switched the wrong display and were undone.
        let strayRetries: Int
    }

    enum Outcome: Equatable, Sendable {
        case arrived(Trip)
        case alreadyShowing
        case failed(String)
    }

    /// How long one press is given to change the display's Space.
    static let pressTimeout = 1.5
    static let pollInterval = 0.03
    /// The topology reports the new Space while the slide is still running.
    static let settleAfterPress = 0.15
    /// Before the window is focused: ordered front while still sliding in,
    /// it is the off-screen window of issue #63 again.
    static let settleOnArrival = 0.25

    /// The longest one trip may take. Presses take a few hundred milliseconds
    /// each; past this something is wrong, and the hook runtime's `--focus`
    /// mode would be stopped by its own deadline mid-trip, with the pointer
    /// still parked on the other display.
    static let maxTripSeconds = 5.0
    /// Presses that switched the wrong display, undone and tried again.
    static let maxStrayRetries = 2

    /// Left for the focus after a trip when the caller has a deadline: the
    /// focus command's own Apple Event timeout, and a little more.
    static let focusReserveSeconds = 3.5

    /// `before` is when the caller's process will be ended, if it will be:
    /// the hook runtime's `--focus` mode has one. The trip ends early enough
    /// to leave the focus its time, and starts no press it could not undo.
    static func travel(to window: OrderedWindow, before callerDeadline: Date? = nil) async
        -> Outcome
    {
        var deadline = Date().addingTimeInterval(maxTripSeconds)
        if let callerDeadline {
            deadline = min(deadline, callerDeadline.addingTimeInterval(-focusReserveSeconds))
        }
        guard WindowServer.isTrusted else { return .failed("Accessibility not granted") }
        guard var topology = WindowServer.topology() else { return .failed("no Space topology") }
        guard let space = window.spaces.first else {
            return .failed("window \(window.number) is on no Space")
        }
        var route = SpaceRoute.to(space, in: topology)
        guard case .hop(let first) = route else {
            return route == .showing ? .alreadyShowing : .failed("Space \(space) is on no display")
        }
        guard WindowServer.displayBounds(first.display) != nil else {
            return .failed("display \(first.display) is not active")
        }
        let pointerBefore = WindowServer.pointer
        defer { if let pointerBefore { WindowServer.movePointer(to: pointerBefore) } }

        var presses = 0
        var strayRetries = 0
        while case .hop(let hop) = route {
            // Room for this press and, should it hit another display, its undo.
            guard Date().addingTimeInterval(2 * pressTimeout) < deadline else {
                return .failed("out of time after \(presses) presses")
            }
            guard presses < SpaceRoute.maxSteps else {
                return .failed("\(presses) presses did not reach Space \(space)")
            }
            guard let shortcut = WindowServer.shortcut(hop.direction) else {
                return .failed("the move-a-space shortcut is switched off")
            }
            guard let bounds = WindowServer.displayBounds(hop.display) else {
                return .failed("display \(hop.display) is not active")
            }
            let before = topology
            await parkPointer(on: bounds)
            WindowServer.press(shortcut)
            presses += 1
            guard let after = await anySpaceChange(from: before) else {
                return .failed("press \(presses) did not switch the Space")
            }
            let strays = after.changedDisplays(since: before).filter { $0 != hop.display }
            if !strays.isEmpty {
                // The press switched a display the trip was not for. Put it
                // back, then try again; a trip that gives up leaves the
                // user's desktops as they were.
                for stray in strays {
                    let original = before.displays.first { $0.identifier == stray }?.current
                    guard let original, await undo(stray, backTo: original, pressed: hop.direction)
                    else {
                        // Pressing on while the desktops are not where they
                        // were would only make it worse.
                        return .failed(
                            "the shortcut switched display \(stray.prefix(8)) and it could not be put back"
                        )
                    }
                }
                guard strayRetries < maxStrayRetries else {
                    return .failed(
                        "the shortcut switched display \(strays[0].prefix(8)), not "
                            + "\(hop.display.prefix(8)), \(strayRetries + 1) times")
                }
                strayRetries += 1
                topology = WindowServer.topology() ?? before
                route = SpaceRoute.to(space, in: topology)
                continue
            }
            await sleep(settleAfterPress)
            topology = WindowServer.topology() ?? after
            route = SpaceRoute.to(space, in: topology)
        }
        guard route == .showing else { return .failed("Space \(space) left its display") }
        await sleep(settleOnArrival)
        return .arrived(
            Trip(
                display: first.display, direction: first.direction, presses: presses,
                strayRetries: strayRetries))
    }

    /// The topology once some display shows another Space than in `before`,
    /// or nil when none has within the timeout.
    private static func anySpaceChange(from before: SpaceTopology) async -> SpaceTopology? {
        let deadline = Date().addingTimeInterval(pressTimeout)
        while Date() < deadline {
            await sleep(pollInterval)
            guard let topology = WindowServer.topology() else { continue }
            if !topology.changedDisplays(since: before).isEmpty { return topology }
        }
        return nil
    }

    /// Moves the pointer to the middle of `bounds` and waits, briefly, until
    /// it is seen there — the shortcut goes to the display the window server
    /// thinks the pointer is on, and a key sent on the heels of the move has
    /// gone to the other display.
    private static func parkPointer(on bounds: CGRect) async {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for _ in 0..<2 {
            WindowServer.movePointer(to: center)
            let until = Date().addingTimeInterval(0.15)
            while Date() < until {
                if let pointer = WindowServer.pointer, bounds.contains(pointer) { return }
                await sleep(0.01)
            }
        }
    }

    /// One press the other way, with the pointer on `display`; true once that
    /// display shows `original` again.
    private static func undo(
        _ display: String, backTo original: UInt64, pressed direction: SpaceHop.Direction
    ) async -> Bool {
        let back: SpaceHop.Direction = direction == .left ? .right : .left
        guard let shortcut = WindowServer.shortcut(back),
            let bounds = WindowServer.displayBounds(display)
        else { return false }
        await parkPointer(on: bounds)
        WindowServer.press(shortcut)
        let deadline = Date().addingTimeInterval(pressTimeout)
        while Date() < deadline {
            await sleep(pollInterval)
            let current = WindowServer.topology()?.displays.first { $0.identifier == display }?
                .current
            if current == original {
                await sleep(settleAfterPress)
                return true
            }
        }
        return false
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
