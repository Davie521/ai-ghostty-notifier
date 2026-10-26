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
        /// Ghostty had a window on a hidden Space and this process is not
        /// allowed to travel there: the Accessibility permission is missing.
        let accessibilityMissing: Bool
    }

    static func run(tabID: String) async -> Report {
        var plan = TabJump(requested: tabID)
        var step = plan.start
        var scripted: [ScriptedWindow] = []
        var route = "window in view"
        var accessibilityMissing = false
        while true {
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
                    if case .unknown = place { route = "window not placed" }
                    step = plan.observe(place: place)
                case .untrusted(let hiddenWindows):
                    accessibilityMissing = hiddenWindows
                    route =
                        hiddenWindows
                        ? "no travel: Accessibility not granted" : "no travel possible or needed"
                    step = plan.observe(place: .unknown)
                case .unanswered(let why):
                    route = "window not placed: \(why)"
                    step = plan.observe(place: .unknown)
                }
            case .hop(let window):
                switch await SpaceHopper.travel(to: window) {
                case .arrived(let trip):
                    let confirmed = confirm(window: plan.window, scripted: scripted)
                    route =
                        "travelled \(trip.presses) \(trip.direction == .left ? "left" : "right") on "
                        + "display \(trip.display.prefix(8)), window \(confirmed ? "in view" : "still out of view")"
                    step = plan.observe(hopResult: .arrived(confirmed: confirmed))
                case .alreadyShowing:
                    route = "window in view"
                    step = plan.observe(hopResult: .arrived(confirmed: true))
                case .failed(let why):
                    route = "no travel: \(why)"
                    step = plan.observe(hopResult: .failed(reason: why))
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
        /// No Accessibility permission. `hiddenWindows` is whether Ghostty
        /// has a window on a hidden Space at all — the window server tells
        /// that much without the permission — so a jump that could not have
        /// needed to travel does not complain.
        case untrusted(hiddenWindows: Bool)
        case unanswered(String)
    }

    private static func survey(window: String, scripted: [ScriptedWindow]) -> Survey {
        guard let pid = Ghostty.processID else { return .unanswered("Ghostty not running") }
        guard let topology = WindowServer.topology() else {
            return .unanswered("no Space topology")
        }
        let ordered = WindowServer.orderedWindows(ownedBy: pid)
        guard WindowServer.isTrusted else {
            return .untrusted(
                hiddenWindows: ordered.contains {
                    !$0.spaces.isEmpty && !topology.shows(anyOf: $0.spaces)
                })
        }
        return .placed(
            WindowPlace.of(
                window, scripted: scripted, ordered: ordered,
                seen: WindowServer.seenWindows(ownedBy: pid),
                visibleSpaces: topology.visibleSpaces))
    }

    /// After a trip: is the window the jump wants among those in view now?
    private static func confirm(window: String?, scripted: [ScriptedWindow]) -> Bool {
        guard let window, case .placed(let place) = survey(window: window, scripted: scripted)
        else { return false }
        return place == .showing
    }

    /// One line for the log, the same from both callers.
    nonisolated static func describe(_ report: Report) -> String {
        let tabID = report.plan.requested
        switch report.outcome {
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
