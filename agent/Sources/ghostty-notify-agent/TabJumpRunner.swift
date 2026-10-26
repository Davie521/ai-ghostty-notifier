import AppKit
import Foundation
import NotifyCore

/// A `TabJumpRun` against the real Ghostty, window server and keyboard: Apple
/// Events to Ghostty, questions to the window server and Accessibility, a
/// trip to another Space. The run decides what to ask and how long to wait;
/// this only asks and sends.
@MainActor
enum TabJumpRunner {
    /// How long a jump waits for another one, in this process or another, to
    /// finish before it gives up and does nothing.
    static let leaseWait = 10.0

    /// `deadline` is when the caller's process will be ended, if it will be:
    /// a trip keeps clear of it, and the wait for another jump leaves the
    /// focus its time before it. `waitUntil` is when the jump stops waiting
    /// for another to finish; `leaseWait` from now unless the caller has
    /// been waiting already.
    static func run(tabID: String, deadline: Date? = nil, waitUntil: Date? = nil) async
        -> TabJumpRun.Report
    {
        var wait = waitUntil ?? Date().addingTimeInterval(leaseWait)
        if let deadline {
            wait = min(wait, deadline.addingTimeInterval(-SpaceHopper.focusReserveSeconds))
        }
        return await TabJumpRun.run(
            tabID, leasePath: leasePath(), leaseUntil: wait,
            driver: LiveDriver(tabID: tabID, deadline: deadline))
    }

    /// Where the lease every jump holds is kept; nil without a home.
    private static func leasePath() -> String? {
        guard let paths = try? AgentPaths(env: ProcessInfo.processInfo.environment) else {
            return nil
        }
        try? PrivateFile.createDirectory(paths.root)
        return paths.root + "/jump"
    }

    @MainActor
    private struct LiveDriver: TabJumpDriver {
        let tabID: String
        let deadline: Date?

        func locate() async -> (TabJump.Probe, [ScriptedWindow]) {
            await Ghostty.locate(tabID: tabID)
        }

        var surveySeconds: Double { WindowServer.seenWindowsBudget }

        func survey(window: String, scripted: [ScriptedWindow], within seconds: Double)
            -> TabJumpSurvey
        {
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
            guard let seen = WindowServer.seenWindows(ownedBy: pid, within: seconds) else {
                return .cutShort
            }
            return .placed(
                WindowPlace.of(
                    window, scripted: scripted, ordered: ordered, seen: seen,
                    visibleSpaces: topology.visibleSpaces))
        }

        func travel(to window: OrderedWindow) async -> SpaceWalk.TripOutcome {
            await SpaceHopper.travel(to: window, before: deadline)
        }

        func restore(_ spots: [SpaceSpot]) async -> Bool { await SpaceHopper.restore(spots) }

        func focus() async -> String? { await Ghostty.focus(tabID: tabID) }

        func selected() async -> String? { await Ghostty.selectedTabID() }

        func timeToLook(puttingBack spots: [SpaceSpot]) -> Double? {
            SpaceHopper.timeToLook(puttingBack: spots)
        }
    }
}
