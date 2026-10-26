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
/// and put back after the trip. A user moving the mouse during the trip can
/// still win that race; a press that switches the wrong display is undone. Every press is checked
/// against the topology before the next and the route recomputed, so a
/// Mission Control that rearranges Spaces by recent use cannot send the trip
/// the wrong way, and a press that changes nothing ends it.
@MainActor
enum SpaceHopper {
    struct Trip: Equatable, Sendable {
        let display: String
        let direction: SpaceHop.Direction
        let presses: Int
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

    static func travel(to window: OrderedWindow) async -> Outcome {
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
        while case .hop(let hop) = route {
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
            // Back to back, so the move is the last thing the window server
            // sees before the key.
            WindowServer.movePointer(to: CGPoint(x: bounds.midX, y: bounds.midY))
            WindowServer.press(shortcut)
            presses += 1
            guard let after = await anySpaceChange(from: before) else {
                return .failed("press \(presses) did not switch the Space")
            }
            let strays = changedDisplays(from: before, to: after).filter { $0 != hop.display }
            if !strays.isEmpty {
                // The press switched a display the trip was not for. Put it
                // back before giving up, so a failed trip leaves the user's
                // desktops as they were.
                for stray in strays { await undo(stray, pressed: hop.direction) }
                return .failed(
                    "the shortcut switched display \(strays[0].prefix(8)), not \(hop.display.prefix(8))"
                )
            }
            await sleep(settleAfterPress)
            topology = WindowServer.topology() ?? after
            route = SpaceRoute.to(space, in: topology)
        }
        guard route == .showing else { return .failed("Space \(space) left its display") }
        await sleep(settleOnArrival)
        return .arrived(Trip(display: first.display, direction: first.direction, presses: presses))
    }

    /// The topology once some display shows another Space than in `before`,
    /// or nil when none has within the timeout.
    private static func anySpaceChange(from before: SpaceTopology) async -> SpaceTopology? {
        let deadline = Date().addingTimeInterval(pressTimeout)
        while Date() < deadline {
            await sleep(pollInterval)
            guard let topology = WindowServer.topology() else { continue }
            if !changedDisplays(from: before, to: topology).isEmpty { return topology }
        }
        return nil
    }

    private static func changedDisplays(from before: SpaceTopology, to after: SpaceTopology)
        -> [String]
    {
        after.displays.compactMap { display in
            let earlier = before.displays.first { $0.identifier == display.identifier }
            return earlier?.current != display.current ? display.identifier : nil
        }
    }

    /// One press the other way, with the pointer on `display`.
    private static func undo(_ display: String, pressed direction: SpaceHop.Direction) async {
        let back: SpaceHop.Direction = direction == .left ? .right : .left
        guard let shortcut = WindowServer.shortcut(back), let before = WindowServer.topology()
        else { return }
        if let bounds = WindowServer.displayBounds(display) {
            WindowServer.movePointer(to: CGPoint(x: bounds.midX, y: bounds.midY))
        }
        WindowServer.press(shortcut)
        _ = await anySpaceChange(from: before)
        await sleep(settleAfterPress)
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
