import AppKit
import Foundation
import NotifyCore

/// Carries out the steps of a `TabJump` — Apple Events to Ghostty, questions
/// to the window server, a trip to another Space — and reports how it went.
/// `TabJump` decides; this only asks and sends.
///
/// Used by the resident's click handling and by the hook runtime's `--focus`
/// mode, so a jump sent from a shell is the same jump a click makes.
@MainActor
enum TabJumpRunner {
    struct Report: Equatable, Sendable {
        let plan: TabJump
        let outcome: TabJump.Outcome
        /// Where the jump went before the focus, for the log.
        let route: String
        /// The tab's window was on a hidden Space and this process is not
        /// allowed to travel there: the Accessibility permission is missing.
        let accessibilityMissing: Bool
    }

    /// `deadline` is when the caller's process will be ended, if it will be;
    /// a trip to another Space keeps clear of it.
    /// How long a jump waits for another one, in this process or another, to
    /// finish before it goes on without travelling.
    static let leaseWait = 10.0

    static func run(tabID: String, deadline: Date? = nil) async -> Report {
        var plan = TabJump(requested: tabID)
        var step = plan.start
        var scripted: [ScriptedWindow] = []
        var route = "window in view"
        var accessibilityMissing = false
        // One jump at a time across processes: the resident's and the
        // `--focus` mode's would interleave their presses and take each
        // other's Space changes for their own. Held to the end, putting back
        // included. A jump that finds another still under way for longer than
        // it waits does nothing at all: even a plain focus could pull a window
        // onto a Space the other jump is only passing through.
        var wait = Date().addingTimeInterval(leaseWait)
        if let deadline {
            wait = min(wait, deadline.addingTimeInterval(-SpaceHopper.focusReserveSeconds))
        }
        // Without a lock file to be had at all, the jump goes on as jumps did
        // before trips: it focuses, and travels nowhere.
        let lease: FileLease?
        switch await jumpLease(until: wait) {
        case .acquired(let held): lease = held
        case .unavailable: lease = nil
        case .held:
            let outcome: TabJump.Outcome = Task.isCancelled ? .abandoned : .busy
            return Report(
                plan: plan, outcome: outcome, route: "another jump was still under way",
                accessibilityMissing: false)
        }
        defer { lease?.release() }
        /// The last trip, once it has arrived, for the log.
        var travelled: String?
        while true {
            // Cancelled with its task — the resident quitting, the `--focus`
            // mode sent SIGTERM — the jump stops where it stands. A trip under
            // way has already walked back by the time it returns here.
            // An end other than these becomes abandoned too: for a not-found
            // or unverified jump the callers would bring Ghostty forward.
            if Task.isCancelled {
                switch step {
                // Putting displays back is putting right: it still happens.
                case .restore, .stop(.verified), .stop(.abandoned), .stop(.strandedTrip): break
                default: step = plan.abandon()
                }
            }
            // With a display moved, a lookup leaves the time to put it back
            // before the process is ended, and a cancellation cuts it short.
            // When there is no time left for one, or it was cut short, the jump
            // gives up and the display goes back.
            var timeToLook: Double?
            if !plan.moved.isEmpty, Self.looksUp(step),
                let left = SpaceHopper.timeToLook(puttingBack: plan.moved)
            {
                if left < leastLookupSeconds {
                    route += "; out of time to look again"
                    step = plan.abandon()
                } else {
                    timeToLook = left
                }
            }
            switch step {
            case .locate:
                guard let (probe, windows) = await locate(tabID, within: timeToLook) else {
                    if plan.moved.isEmpty {
                        // Nothing to put back: the focus answers for itself,
                        // as it does for a lookup that found no answer.
                        route = "window not located: no answer in time"
                        step = plan.observe(probe: .unknown)
                    } else {
                        route += "; no answer in time to look again"
                        step = plan.abandon()
                    }
                    continue
                }
                scripted = windows
                if probe == .unknown { route = "window not located" }
                step = plan.observe(probe: probe)
            case .survey(let window):
                let survey = survey(
                    window: window, scripted: scripted, leased: lease != nil, within: timeToLook)
                switch survey {
                case .placed(let place):
                    if let travelled {
                        // The look after a trip, with titles read after it.
                        let seen = place == .showing ? "window in view" : "window still out of view"
                        route = "\(travelled), \(seen)"
                    } else if case .unknown = place {
                        route = "window not placed"
                    } else if case .unsettled = place {
                        route = "window lists did not pair, read \(plan.rereads + 1) time(s)"
                    }
                    step = plan.observe(place: place)
                case .untrusted(let mayBeOutOfView):
                    // Without the permission no trip can happen; the focus
                    // is the one the jump always made.
                    accessibilityMissing = mayBeOutOfView
                    route =
                        mayBeOutOfView
                        ? "no travel: Accessibility not granted" : "window in view or not placed"
                    step = plan.observe(place: .unknown)
                case .unanswered(let why):
                    route = "window not placed: \(why)"
                    step = plan.observe(place: .unknown)
                case .outOfTime:
                    route += "; out of time to look again"
                    step = plan.abandon()
                }
            case .hop(let window):
                switch await SpaceHopper.travel(to: window, before: deadline) {
                case .arrived(let trip):
                    let retried =
                        trip.strayRetries > 0
                        ? " after undoing \(trip.strayRetries) press(es) on another display" : ""
                    travelled =
                        "travelled \(trip.presses) \(trip.direction == .left ? "left" : "right") on "
                        + "display \(trip.display.prefix(8))\(retried)"
                    route = travelled ?? route
                    step = plan.observe(
                        hopResult: .arrived(
                            from: SpaceSpot(display: trip.display, space: trip.from)))
                case .alreadyShowing:
                    travelled = "no travel: the Space came into view by itself"
                    route = travelled ?? route
                    step = plan.observe(hopResult: .arrived(from: nil))
                case .failed(let why):
                    travelled = nil
                    route = "no travel: \(why)"
                    step = plan.observe(hopResult: .failed(reason: why))
                case .stranded(let why):
                    travelled = nil
                    route = "trip left unfinished: \(why)"
                    step = plan.observe(hopResult: .stranded(reason: why))
                }
            case .restore(let spots):
                let back = await SpaceHopper.restore(spots)
                route += back ? "; went back to where the jump began" : "; could not go back"
                step = plan.observe(restored: back)
            case .focus:
                let selected = await Ghostty.focus(tabID: tabID)
                step = plan.observe(focusResult: selected)
            case .verify(let delay):
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let selected = await Ghostty.selectedTabID()
                step = plan.observe(selected: selected)
            case .stop(let outcome):
                return Report(
                    plan: plan, outcome: outcome, route: route,
                    accessibilityMissing: accessibilityMissing)
            }
        }
    }

    private enum Survey {
        case placed(WindowPlace)
        /// No Accessibility permission. `mayBeOutOfView` is whether the
        /// window may be on a hidden Space, so only a jump that may have
        /// needed to travel asks for the permission.
        case untrusted(mayBeOutOfView: Bool)
        case unanswered(String)
        /// The read ran out of the time it had left before a display a trip
        /// moved had to go back.
        case outOfTime
    }

    /// Less than this, and a lookup would only be cut short.
    static let leastLookupSeconds = 0.3
    /// The locate script's Apple Event timeout, and a little more.
    static let locateSeconds = 3.5
    /// How long a lookup cancelled with its jump may still take: a healthy one
    /// has answered by then, and a jump being given up waits no longer.
    static let cancelledLookupSeconds = 0.25

    private static func looksUp(_ step: TabJump.Step) -> Bool {
        switch step {
        case .locate, .survey: return true
        default: return false
        }
    }

    /// The lookup; nil when it was cut short, its late answer dropped: by
    /// `seconds`, at most the locate script's own timeout, and by a
    /// cancellation of the jump. Its Apple Event timeout bounds each command
    /// the script sends, not the script, and the jump holds the lease that
    /// every other jump waits for.
    private static func locate(_ tabID: String, within seconds: Double?) async
        -> (TabJump.Probe, [ScriptedWindow])?
    {
        try? await QueryDeadline.run(
            seconds: min(locateSeconds, seconds ?? locateSeconds),
            cancelledSeconds: cancelledLookupSeconds
        ) { await Ghostty.locate(tabID: tabID) }
    }

    /// The lease every jump holds while it runs. `held` once another jump has
    /// held it until `deadline`, or this one was cancelled while waiting;
    /// `unavailable` when there is no lock file to be had at all — no home,
    /// an unwritable state directory.
    private static func jumpLease(until deadline: Date) async -> FileLease.Attempt {
        guard let paths = try? AgentPaths(env: ProcessInfo.processInfo.environment) else {
            return .unavailable
        }
        try? PrivateFile.createDirectory(paths.root)
        while true {
            // A try, not a wait: `FileLease.acquire` waits by blocking its
            // thread, and this is the main actor.
            let attempt = FileLease.attempt(paths.root + "/jump")
            guard case .held = attempt else { return attempt }
            guard Date() < deadline, !Task.isCancelled else { return .held }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
    }

    /// Where the window is. `within` bounds the Accessibility read when a
    /// display a trip moved has to go back in time.
    private static func survey(
        window: String, scripted: [ScriptedWindow], leased: Bool, within limit: Double?
    ) -> Survey {
        guard leased else { return .unanswered("no lock file to keep jumps apart") }
        guard let pid = Ghostty.processID else { return .unanswered("Ghostty not running") }
        guard let topology = WindowServer.topology() else {
            return .unanswered("no Space topology")
        }
        let ordered = WindowServer.orderedWindows(ownedBy: pid)
        guard WindowServer.isTrusted else {
            let place = WindowPlace.of(
                window, scripted: scripted, ordered: ordered, seen: nil,
                visibleSpaces: topology.visibleSpaces)
            return .untrusted(mayBeOutOfView: place.mayBeOutOfView)
        }
        let budget = min(WindowServer.seenWindowsBudget, limit ?? .infinity)
        guard let seen = WindowServer.seenWindows(ownedBy: pid, within: budget) else {
            if budget < WindowServer.seenWindowsBudget { return .outOfTime }
            return .unanswered("Ghostty did not answer Accessibility in time")
        }
        return .placed(
            WindowPlace.of(
                window, scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: topology.visibleSpaces))
    }

    /// One line for the log, the same from both callers.
    nonisolated static func describe(_ report: Report) -> String {
        let tabID = report.plan.requested
        switch report.outcome {
        case .abandoned:
            return "jump: gave up on \(tabID) (\(report.route)), stopping"
        case .strandedTrip:
            return "jump: \(tabID) not focused (\(report.route))"
        case .busy:
            return "jump: \(tabID) left alone (\(report.route))"
        case .notFound:
            return "jump: \(tabID) not found, activated Ghostty only"
        case .verified(reads: 0, focusAttempts: 1):
            return "jump: focused \(tabID) (\(report.route)), verified selected"
        case .verified(let reads, let attempts):
            // The first read raced the focus. Logged apart from the plain
            // case so the log keeps counting how often that happens.
            return
                "jump: focused \(tabID) (\(report.route)), verified selected after \(reads) "
                + "re-read(s), \(attempts) focus attempt(s)"
        case .unverified(let selected, let attempts):
            // Focusing reported success but the selection never followed.
            // Worth its own line: it is the difference between "we asked"
            // and "it happened", and the two look identical from outside.
            return
                "jump: asked for \(tabID) (\(report.route)) but \(selected ?? "<none>") is "
                + "selected after \(attempts) focus attempt(s)"
        }
    }
}
