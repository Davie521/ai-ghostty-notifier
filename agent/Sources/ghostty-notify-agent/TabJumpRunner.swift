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
    static func run(tabID: String, deadline: Date? = nil) async -> Report {
        var plan = TabJump(requested: tabID)
        var step = plan.start
        var scripted: [ScriptedWindow] = []
        var route = "window in view"
        var accessibilityMissing = false
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
                case .stop(.verified), .stop(.abandoned), .stop(.strandedTrip): break
                default: step = plan.abandon()
                }
            }
            switch step {
            case .locate:
                let (probe, windows) = await Ghostty.locate(tabID: tabID)
                scripted = windows
                if probe == .unknown { route = "window not located" }
                step = plan.observe(probe: probe)
            case .survey(let window):
                let survey = survey(window: window, scripted: scripted)
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
                case .untrusted(let targetHidden):
                    // Without the permission no trip can happen; the focus
                    // is the one the jump always made.
                    accessibilityMissing = targetHidden
                    route =
                        targetHidden
                        ? "no travel: Accessibility not granted" : "window in view or not placed"
                    step = plan.observe(place: .unknown)
                case .unanswered(let why):
                    route = "window not placed: \(why)"
                    step = plan.observe(place: .unknown)
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
                    step = plan.observe(hopResult: .arrived)
                case .alreadyShowing:
                    travelled = "no travel: the Space came into view by itself"
                    route = travelled ?? route
                    step = plan.observe(hopResult: .arrived)
                case .failed(let why):
                    travelled = nil
                    route = "no travel: \(why)"
                    step = plan.observe(hopResult: .failed(reason: why))
                case .stranded(let why):
                    travelled = nil
                    route = "trip left unfinished: \(why)"
                    step = plan.observe(hopResult: .stranded(reason: why))
                }
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
        /// No Accessibility permission. `targetHidden` is whether the order
        /// alone placed the window on a hidden Space, so only a jump that
        /// needed to travel asks for the permission.
        case untrusted(targetHidden: Bool)
        case unanswered(String)
    }

    private static func survey(window: String, scripted: [ScriptedWindow]) -> Survey {
        guard let pid = Ghostty.processID else { return .unanswered("Ghostty not running") }
        guard let topology = WindowServer.topology() else {
            return .unanswered("no Space topology")
        }
        let ordered = WindowServer.orderedWindows(ownedBy: pid)
        guard WindowServer.isTrusted else {
            let place = WindowPlace.of(
                window, scripted: scripted, ordered: ordered, seen: nil,
                visibleSpaces: topology.visibleSpaces)
            if case .hidden = place { return .untrusted(targetHidden: true) }
            return .untrusted(targetHidden: false)
        }
        return .placed(
            WindowPlace.of(
                window, scripted: scripted, ordered: ordered,
                seen: WindowServer.seenWindows(ownedBy: pid),
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
