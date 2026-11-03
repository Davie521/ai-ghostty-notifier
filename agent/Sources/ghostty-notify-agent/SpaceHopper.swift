import AppKit
import NotifyCore

/// Brings a window's Space into view: straight there by bringing the window
/// forward as window switchers do, and failing that the way the user would,
/// by pressing their "move left/right a space" shortcut on the display that
/// has the Space, as many times as it takes. The trip itself is `SpaceWalk`'s;
/// this is the window server, Accessibility and the keyboard under it.
///
/// The window server's part of bringing a window forward, tried alone,
/// fronted nothing on one machine (macOS 26.6.2) while Ghostty had a window in
/// view on the other display; the shortcut switched every time. With the
/// Accessibility raise after it, it switched straight to the window's Space on
/// macOS 27 (one display) every time, where the walk showed every Space
/// between — Ghostty's other window among them, as often as not. Hence the
/// switch first and the walk after it, should no display have switched.
/// `GHOSTTY_NOTIFY_SPACE_TRAVEL=walk` leaves the switch out.
///
/// The shortcut acts on the display under the pointer — measured: with the
/// key window on one display and the pointer on the other, the pointer's
/// display switched — so the pointer is moved there right before every press,
/// the press waits until the pointer is seen there, and the pointer is put
/// back after the trip. A press still landed on the other display once in
/// nine live runs, which is what the walk's undo and retry are for.
@MainActor
enum SpaceHopper {
    /// The longest one trip may take: sixteen presses, the most a route
    /// allows, at the few hundred milliseconds each takes.
    static let maxTripSeconds = 8.0
    /// Left for the focus after a trip when the caller has a deadline: the
    /// focus command's own Apple Event timeout, and a little more.
    static let focusReserveSeconds = 3.5
    /// Kept clear of the process's end by every press, a walk back's included.
    static let hardReserveSeconds = 1.0

    /// When the resident, quitting, stops waiting for a trip: set as it starts
    /// to shut down, and kept clear of by every press from then on.
    static var shutdownDeadline: Date?
    /// Where the pointer was when the trip began, while one is under way.
    private static var pointerToRestore: CGPoint?
    /// Whether this trip has moved the pointer. A switch straight to a Space
    /// does not, and then the pointer is left where the user has it now: put
    /// back, it would jump under a hand that moved on after the click.
    private static var pointerMoved = false
    /// Whether a trip is under way.
    private(set) static var isTravelling = false

    /// Puts the pointer back if a trip is still under way: the last resort of
    /// a shutdown that could not wait any longer for the trip to end.
    @discardableResult
    static func restorePointerIfTravelling() -> Bool {
        guard isTravelling, pointerMoved, let pointerToRestore else { return false }
        WindowServer.movePointer(to: pointerToRestore)
        return true
    }

    /// `before` is when the caller's process will be ended, if it will be:
    /// the hook runtime's `--focus` mode has one, and ends with `_exit`, which
    /// leaves no chance to put the pointer back. The trip onward ends early
    /// enough to leave the focus its time.
    ///
    /// A trip cancelled with the task it runs in — the resident quitting, the
    /// `--focus` mode sent SIGTERM — stops going onward, walks back, and puts
    /// the pointer back.
    static func travel(to window: OrderedWindow, before callerDeadline: Date? = nil) async
        -> SpaceWalk.TripOutcome
    {
        guard WindowServer.isTrusted else { return .failed("Accessibility not granted") }
        guard let space = window.spaces.first else {
            return .failed("window \(window.number) is on no Space")
        }
        var deadline = Date().addingTimeInterval(maxTripSeconds)
        if let callerDeadline {
            deadline = min(deadline, callerDeadline.addingTimeInterval(-focusReserveSeconds))
        }
        pointerToRestore = WindowServer.pointer
        pointerMoved = false
        isTravelling = true
        defer {
            if pointerMoved, let pointerToRestore { WindowServer.movePointer(to: pointerToRestore) }
            pointerToRestore = nil
            isTravelling = false
        }
        return await SpaceWalk.travel(
            to: space, window: walksOnly ? nil : window.number, deadline: deadline,
            driver: LiveDriver())
    }

    /// Set to `walk`, trips never switch straight to a Space: for the live
    /// check of a trip cut short, and for a macOS on which the switch goes
    /// wrong.
    static var walksOnly: Bool {
        ProcessInfo.processInfo.environment["GHOSTTY_NOTIFY_SPACE_TRAVEL"] == "walk"
    }

    /// When the process will be ended, less the reserve every press keeps
    /// clear of it: the `--focus` mode's own deadline, or the resident's once
    /// it starts to shut down. `distantFuture` otherwise.
    static func hardDeadline() -> Date {
        let ends = [NativeLifecycle.deadline, shutdownDeadline].compactMap { $0 }
        guard let end = ends.min() else { return .distantFuture }
        return end.addingTimeInterval(-hardReserveSeconds)
    }

    /// How long a lookup may take now and still leave the time to put these
    /// displays back before the process is ended; nil when it has no end in
    /// sight.
    static func timeToLook(puttingBack spots: [SpaceSpot]) -> Double? {
        let end = hardDeadline()
        return SpaceWalk.timeToLook(
            puttingBack: spots, now: Date(), hardDeadline: end,
            topology: end == .distantFuture ? nil : WindowServer.topology())
    }

    /// Puts displays back on the Spaces they showed before trips moved them.
    /// Putting right, so it runs even in a jump that is being given up, and
    /// it puts the pointer back. True when every display is back.
    static func restore(_ spots: [SpaceSpot]) async -> Bool {
        guard WindowServer.isTrusted else { return false }
        pointerToRestore = WindowServer.pointer
        pointerMoved = false
        isTravelling = true
        defer {
            if pointerMoved, let pointerToRestore { WindowServer.movePointer(to: pointerToRestore) }
            pointerToRestore = nil
            isTravelling = false
        }
        var allBack = true
        for spot in spots {
            if case .arrived = await SpaceWalk.goBack(to: spot, driver: LiveDriver()) { continue }
            allBack = false
        }
        return allBack
    }

    /// The window server and the keyboard, for `SpaceWalk`.
    private struct LiveDriver: SpaceWalkDriver {
        static let pollInterval = 0.03

        func topology() -> SpaceTopology? { WindowServer.topology() }

        func hasShortcut(_ direction: SpaceHop.Direction) -> Bool {
            WindowServer.shortcut(direction) != nil
        }

        func press(_ direction: SpaceHop.Direction, on display: String) async -> Bool {
            guard let shortcut = WindowServer.shortcut(direction),
                let bounds = WindowServer.displayBounds(display)
            else { return false }
            await parkPointer(on: bounds)
            WindowServer.press(shortcut)
            return true
        }

        func poll(within timeout: Double, until done: (SpaceTopology) -> Bool) async
            -> SpaceTopology?
        {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                await pause(Self.pollInterval)
                if let topology = WindowServer.topology(), done(topology) { return topology }
            }
            return nil
        }

        func now() -> Date { Date() }

        /// Not `Task.sleep`, which returns at once in a cancelled task: the
        /// undo and the walk back that follow a cancellation still need their
        /// waits, or their presses would run into each other.
        func pause(_ seconds: Double) async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    continuation.resume()
                }
            }
        }

        func stopRequested() -> Bool { Task.isCancelled }

        func hardDeadline() -> Date { SpaceHopper.hardDeadline() }

        func raise(_ window: UInt32) async -> Bool {
            guard let pid = Ghostty.processID else { return false }
            return WindowServer.raise(CGWindowID(window), ownedBy: pid)
        }

        func spaces(of window: UInt32) -> [UInt64]? {
            WindowServer.spaces(of: CGWindowID(window))
        }

        /// Moves the pointer to the middle of `bounds` and waits, briefly,
        /// until it is seen there: the shortcut goes to the display the window
        /// server thinks the pointer is on, and a key sent on the heels of the
        /// move has gone to the other display.
        private func parkPointer(on bounds: CGRect) async {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            SpaceHopper.pointerMoved = true
            for _ in 0..<2 {
                WindowServer.movePointer(to: center)
                // Two tries within the time the walk budgets for parking.
                let until = Date().addingTimeInterval(SpaceWalk.parkSeconds / 2)
                while Date() < until {
                    if let pointer = WindowServer.pointer, bounds.contains(pointer) { return }
                    await pause(0.01)
                }
            }
        }
    }
}
