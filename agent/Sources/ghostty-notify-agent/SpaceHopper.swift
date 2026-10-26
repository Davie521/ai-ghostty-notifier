import AppKit
import NotifyCore

/// Brings a window's Space into view the way the user would: by pressing
/// their "move left/right a space" shortcut, on the display that has the
/// Space, as many times as it takes. The walk itself is `SpaceWalk`'s; this
/// is the window server and the keyboard under it.
///
/// Asking the window server to front the window, as the window switchers
/// do, fronted nothing on this machine (macOS 26.6.2) while Ghostty had a
/// window in view on the other display; the shortcut switched every time.
/// The shortcut acts on the display under the pointer — measured: with the
/// key window on one display and the pointer on the other, the pointer's
/// display switched — so the pointer is moved there right before every press,
/// the press waits until the pointer is seen there, and the pointer is put
/// back after the trip. A press still landed on the other display once in
/// nine live runs, which is what the walk's undo and retry are for.
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

    /// Before the window is focused: ordered front while still sliding in,
    /// it is the off-screen window of issue #63 again.
    static let settleOnArrival = 0.25
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
    /// Whether a trip is under way.
    private(set) static var isTravelling = false

    /// Puts the pointer back if a trip is still under way: the last resort of
    /// a shutdown that could not wait any longer for the trip to end.
    @discardableResult
    static func restorePointerIfTravelling() -> Bool {
        guard isTravelling, let pointerToRestore else { return false }
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
        -> Outcome
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
        isTravelling = true
        defer {
            if let pointerToRestore { WindowServer.movePointer(to: pointerToRestore) }
            pointerToRestore = nil
            isTravelling = false
        }
        let outcome = await SpaceWalk.travel(to: space, deadline: deadline, driver: LiveDriver())
        switch outcome {
        case .arrived(let display, let direction, let presses, let strayRetries):
            await LiveDriver().pause(settleOnArrival)
            return .arrived(
                Trip(
                    display: display, direction: direction, presses: presses,
                    strayRetries: strayRetries))
        case .alreadyShowing:
            return .alreadyShowing
        case .failed(let why):
            return .failed(why)
        }
    }

    /// The window server and the keyboard, for `SpaceWalk`.
    private struct LiveDriver: SpaceWalkDriver {
        static let pollInterval = 0.03

        func topology() -> SpaceTopology? { WindowServer.topology() }

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

        func hardDeadline() -> Date {
            let ends = [NativeLifecycle.deadline, SpaceHopper.shutdownDeadline].compactMap { $0 }
            guard let end = ends.min() else { return .distantFuture }
            return end.addingTimeInterval(-SpaceHopper.hardReserveSeconds)
        }

        /// Moves the pointer to the middle of `bounds` and waits, briefly,
        /// until it is seen there: the shortcut goes to the display the window
        /// server thinks the pointer is on, and a key sent on the heels of the
        /// move has gone to the other display.
        private func parkPointer(on bounds: CGRect) async {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            for _ in 0..<2 {
                WindowServer.movePointer(to: center)
                let until = Date().addingTimeInterval(0.15)
                while Date() < until {
                    if let pointer = WindowServer.pointer, bounds.contains(pointer) { return }
                    await pause(0.01)
                }
            }
        }
    }
}
