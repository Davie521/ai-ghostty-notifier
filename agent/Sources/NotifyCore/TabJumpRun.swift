import Foundation

/// What a jump's steps ask of Ghostty, the window server and the keyboard, so
/// that `TabJumpRun` can carry them out, and tests walk them, without any of
/// them.
@MainActor
public protocol TabJumpDriver: Sendable {
    /// Which window holds the tab, and every one of Ghostty's windows with its
    /// title, front to back. As slow as Ghostty is: the run bounds it.
    func locate() async -> (TabJump.Probe, [ScriptedWindow])
    /// The longest a survey's reads take when nothing else limits them.
    var surveySeconds: Double { get }
    /// Where `window` is, its reads kept within `seconds`.
    func survey(window: String, scripted: [ScriptedWindow], within seconds: Double)
        -> TabJumpSurvey
    /// A trip to the window's Space. It keeps its own time.
    func travel(to window: OrderedWindow) async -> SpaceWalk.TripOutcome
    /// Puts displays back on the Spaces they showed; true when all are.
    func restore(_ spots: [SpaceSpot]) async -> Bool
    /// The focus command: the front window's selection afterwards, or nil.
    func focus() async -> String?
    /// Which tab is selected. As slow as Ghostty is: the run bounds it.
    func selected() async -> String?
    /// How long a lookup may take now and still leave the time to put these
    /// displays back before the process is ended; nil with no end in sight.
    func timeToLook(puttingBack spots: [SpaceSpot]) -> Double?
}

/// Where a survey placed the window, or why it could not.
public enum TabJumpSurvey: Equatable, Sendable {
    case placed(WindowPlace)
    /// No Accessibility permission. `mayBeOutOfView` is whether the window
    /// may be on a hidden Space, so only a jump that may have needed to travel
    /// asks for the permission.
    case untrusted(mayBeOutOfView: Bool)
    /// No answer, for the reason given.
    case unanswered(String)
    /// The reads did not finish within the time they were given.
    case cutShort
}

/// Carries out the steps of a `TabJump` and reports how it went. `TabJump`
/// decides; this asks the driver, and keeps every question that may go
/// unanswered within its time. A jump holds the lease every other jump waits
/// for, so nothing it waits on may be an answer that never comes — and once a
/// trip has moved a display, nothing may use up the time to put it back.
///
/// Used by the resident's click handling and by the hook runtime's `--focus`
/// mode, so a jump sent from a shell is the same jump a click makes.
@MainActor
public enum TabJumpRun {
    public struct Report: Equatable, Sendable {
        public let plan: TabJump
        public let outcome: TabJump.Outcome
        /// Where the jump went before the focus, for the log.
        public let route: String
        /// The tab's window may have been on a hidden Space, and this process
        /// is not allowed to travel there: the Accessibility permission is
        /// missing.
        public let accessibilityMissing: Bool
    }

    public struct Limits: Sendable {
        /// The longest a lookup or a read of the selection is waited for. The
        /// scripts' own Apple Event timeout bounds each command they send, not
        /// the script.
        public var querySeconds: Double
        /// How long one may still take once the jump is cancelled: a healthy
        /// one has answered by then, and a jump being given up waits no longer.
        public var cancelledSeconds: Double
        /// With less than this left before a display a trip moved must go
        /// back, a lookup would only be cut short.
        public var leastLookupSeconds: Double

        public init(
            querySeconds: Double = 3.5, cancelledSeconds: Double = 0.25,
            leastLookupSeconds: Double = 0.3
        ) {
            self.querySeconds = querySeconds
            self.cancelledSeconds = cancelledSeconds
            self.leastLookupSeconds = leastLookupSeconds
        }
    }

    /// One jump at a time across processes: the resident's and the `--focus`
    /// mode's would interleave their presses and take each other's Space
    /// changes for their own. The lease at `leasePath` is held to the end,
    /// putting back included. A jump that finds another still under way at
    /// `leaseUntil` does nothing at all: even a plain focus could pull a window
    /// onto a Space the other jump is only passing through. With no lock file
    /// to be had — `leasePath` nil, or a file that cannot be created — the
    /// jump goes on as jumps did before trips: it focuses, and travels nowhere.
    public static func run(
        _ requested: String, leasePath: String?, leaseUntil: Date, limits: Limits = Limits(),
        driver: some TabJumpDriver
    ) async -> Report {
        let plan = TabJump(requested: requested)
        let lease: FileLease?
        switch await waitForLease(at: leasePath, until: leaseUntil) {
        case .acquired(let held): lease = held
        case .unavailable: lease = nil
        case .held:
            return Report(
                plan: plan, outcome: Task.isCancelled ? .abandoned : .busy,
                route: "another jump was still under way", accessibilityMissing: false)
        }
        defer { lease?.release() }
        return await steps(plan, leased: lease != nil, limits: limits, driver: driver)
    }

    /// `held` once another jump has held the lease until `deadline`, or this
    /// one was cancelled while waiting for it.
    static func waitForLease(at path: String?, until deadline: Date) async -> FileLease.Attempt {
        guard let path else { return .unavailable }
        while true {
            // One try at a time: `FileLease.acquire` waits by blocking its
            // thread, and this runs on the main actor.
            let attempt = FileLease.attempt(path)
            guard case .held = attempt else { return attempt }
            guard Date() < deadline, !Task.isCancelled else { return .held }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func steps(
        _ start: TabJump, leased: Bool, limits: Limits, driver: some TabJumpDriver
    ) async -> Report {
        var plan = start
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
                // Putting displays back is putting right: it still happens.
                case .restore, .stop(.verified), .stop(.abandoned), .stop(.strandedTrip): break
                default: step = plan.abandon()
                }
            }
            // With a display moved, a lookup leaves the time to put it back
            // before the process is ended. When there is no time left for one,
            // or it was cut short, the jump gives up and the display goes back.
            var timeToLook: Double?
            if !plan.moved.isEmpty, looksUp(step),
                let left = driver.timeToLook(puttingBack: plan.moved)
            {
                if left < limits.leastLookupSeconds {
                    route += "; out of time to look again"
                    step = plan.abandon()
                } else {
                    timeToLook = left
                }
            }
            switch step {
            case .locate:
                let seconds = min(limits.querySeconds, timeToLook ?? limits.querySeconds)
                guard
                    let (probe, windows) = await bounded(seconds, limits, { await driver.locate() })
                else {
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
                // Without the lease no trip: another jump's may be under way.
                guard leased else {
                    route = "window not placed: no lock file to keep jumps apart"
                    step = plan.observe(place: .unknown)
                    continue
                }
                let seconds = min(driver.surveySeconds, timeToLook ?? driver.surveySeconds)
                switch driver.survey(window: window, scripted: scripted, within: seconds) {
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
                case .cutShort:
                    if seconds < driver.surveySeconds {
                        // Cut short by the time a moved display needs to go back.
                        route += "; out of time to look again"
                        step = plan.abandon()
                    } else {
                        route = "window not placed: Ghostty did not answer Accessibility in time"
                        step = plan.observe(place: .unknown)
                    }
                }
            case .hop(let window):
                switch await driver.travel(to: window) {
                case .arrived(let display, let from, let direction, let presses, let strayRetries):
                    let retried =
                        strayRetries > 0
                        ? " after undoing \(strayRetries) press(es) on another display" : ""
                    travelled =
                        "travelled \(presses) \(direction == .left ? "left" : "right") on "
                        + "display \(display.prefix(8))\(retried)"
                    route = travelled ?? route
                    step = plan.observe(
                        hopResult: .arrived(from: SpaceSpot(display: display, space: from)))
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
                let back = await driver.restore(spots)
                route += back ? "; went back to where the jump began" : "; could not go back"
                step = plan.observe(restored: back)
            case .focus:
                step = plan.observe(focusResult: await driver.focus())
            case .verify(let delay):
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard
                    let selected = await bounded(
                        limits.querySeconds, limits, { await driver.selected() })
                else {
                    // No answer in time is no selection at all.
                    route += "; selection not read in time"
                    step = plan.observe(selected: nil)
                    continue
                }
                step = plan.observe(selected: selected)
            case .stop(let outcome):
                return Report(
                    plan: plan, outcome: outcome, route: route,
                    accessibilityMissing: accessibilityMissing)
            }
        }
    }

    private static func looksUp(_ step: TabJump.Step) -> Bool {
        switch step {
        case .locate, .survey: return true
        default: return false
        }
    }

    /// `work`, waited for `seconds` at most, and once the jump is cancelled
    /// for `limits.cancelledSeconds`; nil then, and its late answer dropped.
    private static func bounded<Value: Sendable>(
        _ seconds: Double, _ limits: Limits, _ work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        try? await QueryDeadline.run(seconds: seconds, cancelledSeconds: limits.cancelledSeconds) {
            await work()
        }
    }

    /// One line for the log, the same from both callers.
    public nonisolated static func describe(_ report: Report) -> String {
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
