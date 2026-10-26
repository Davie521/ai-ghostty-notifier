import Foundation
import Testing

@testable import NotifyCore

/// Ghostty, the window server and the keyboard on paper, for one jump. Every
/// answer can be made to take its time, as a busy or stuck Ghostty's does.
@MainActor
final class FakeJump: TabJumpDriver {
    let requested: String
    /// What each lookup answers, in turn, and after how many seconds; the
    /// last one answers every lookup after it.
    var lookups: [(seconds: Double, probe: TabJump.Probe)] = [(0, .found(window: "w1"))]
    /// What each survey answers, in turn; the last one answers every survey
    /// after it.
    var surveys: [TabJumpSurvey] = [.placed(.showing)]
    let surveySeconds = 1.5
    private(set) var surveyedWithin: [Double] = []
    var trips: [SpaceWalk.TripOutcome] = []
    private(set) var restored: [[SpaceSpot]] = []
    /// The selection the focus command reports.
    var focusSelects: String?
    /// What a read of the selection answers, and after how many seconds.
    var selection: (seconds: Double, tab: String?)
    /// Time left to look with a display moved; nil with no end in sight.
    var left: Double?
    private(set) var calls: [String] = []

    init(_ requested: String) {
        self.requested = requested
        focusSelects = requested
        selection = (0, requested)
    }

    func locate() async -> (TabJump.Probe, [ScriptedWindow]) {
        calls.append("locate")
        let answer = lookups.count > 1 ? lookups.removeFirst() : lookups[0]
        await take(answer.seconds)
        return (answer.probe, [])
    }

    func survey(window: String, scripted: [ScriptedWindow], within seconds: Double)
        -> TabJumpSurvey
    {
        calls.append("survey")
        surveyedWithin.append(seconds)
        return surveys.count > 1 ? surveys.removeFirst() : surveys[0]
    }

    func travel(to window: OrderedWindow) async -> SpaceWalk.TripOutcome {
        calls.append("travel")
        return trips.isEmpty ? .failed("no trip scripted") : trips.removeFirst()
    }

    func restore(_ spots: [SpaceSpot]) async -> Bool {
        calls.append("restore")
        restored.append(spots)
        return true
    }

    func focus() async -> String? {
        calls.append("focus")
        return focusSelects
    }

    func selected() async -> String? {
        calls.append("selected")
        await take(selection.seconds)
        return selection.tab
    }

    func timeToLook(puttingBack spots: [SpaceSpot]) -> Double? { left }

    /// Like a reply that has not come yet. A query cut short stops waiting
    /// for it; this one also stops when it is cancelled, so it does not
    /// outlive the test.
    private func take(_ seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

@MainActor
@Suite struct TabJumpRunTests {
    /// Short limits, so that what is cut short is cut short at once.
    let limits = TabJumpRun.Limits(
        querySeconds: 0.2, cancelledSeconds: 0.05, leastLookupSeconds: 0.1)
    let hidden = TabJumpSurvey.placed(
        .hidden(candidates: [OrderedWindow(number: 7, spaces: [2])]))
    let arrived = SpaceWalk.TripOutcome.arrived(
        display: "A", from: 1, direction: .right, presses: 1, strayRetries: 0)
    let home = SpaceSpot(display: "A", space: 1)

    func steps(_ fake: FakeJump, leased: Bool = true, limits: TabJumpRun.Limits? = nil) async
        -> TabJumpRun.Report
    {
        await TabJumpRun.steps(
            TabJump(requested: fake.requested), leased: leased, limits: limits ?? self.limits,
            driver: fake)
    }

    func scratchLease() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tab-jump-" + UUID().uuidString
        ).path
    }

    @Test func aWindowInViewIsFocusedWithoutATrip() async {
        let fake = FakeJump("t1")
        let report = await steps(fake)
        #expect(report.outcome == .verified(reads: 0, focusAttempts: 1))
        #expect(fake.calls == ["locate", "survey", "focus"])
        #expect(report.route == "window in view")
    }

    @Test func aHiddenWindowIsTravelledToAndLookedAtAgainBeforeTheFocus() async {
        let fake = FakeJump("t1")
        fake.surveys = [hidden, .placed(.showing)]
        fake.trips = [arrived]
        let report = await steps(fake)
        #expect(report.outcome == .verified(reads: 0, focusAttempts: 1))
        #expect(fake.calls == ["locate", "survey", "travel", "locate", "survey", "focus"])
        #expect(report.route == "travelled 1 right on display A, window in view")
        #expect(fake.restored.isEmpty)
    }

    /// The first lookup does not answer: nothing has moved, and the focus
    /// answers for itself, as it does for a lookup with no answer.
    @Test func aFirstLookupWithNoAnswerInTimeFallsBackToTheFocus() async {
        let fake = FakeJump("t1")
        fake.lookups = [(10, .found(window: "w1"))]
        let started = Date()
        let report = await steps(fake)
        #expect(report.outcome == .verified(reads: 0, focusAttempts: 1))
        #expect(fake.calls == ["locate", "focus"])
        #expect(report.route == "window not located: no answer in time")
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// After a trip, a lookup that does not answer leaves the display on a
    /// Space nobody has seen the window on: it goes back, and nothing is
    /// focused.
    @Test func aLookupAfterATripWithNoAnswerInTimePutsTheDisplayBack() async {
        let fake = FakeJump("t1")
        fake.lookups = [(0, .found(window: "w1")), (10, .found(window: "w1"))]
        fake.surveys = [hidden]
        fake.trips = [arrived]
        fake.left = 5
        let report = await steps(fake)
        #expect(report.outcome == .abandoned)
        #expect(fake.calls == ["locate", "survey", "travel", "locate", "restore"])
        #expect(fake.restored == [[home]])
        #expect(report.route.contains("no answer in time to look again"))
    }

    /// A lookup after a trip gets only the time left before the display must
    /// go back, less than a lookup is otherwise given.
    @Test func aLookupAfterATripGetsOnlyTheTimeLeft() async {
        let fake = FakeJump("t1")
        fake.lookups = [(0, .found(window: "w1")), (0.15, .found(window: "w1"))]
        fake.surveys = [hidden, .placed(.showing)]
        fake.trips = [arrived]
        fake.left = 0.12
        let report = await steps(fake)
        #expect(report.outcome == .abandoned)
        #expect(fake.restored == [[home]])
        #expect(!fake.calls.contains("focus"))
    }

    @Test func noLookupStartsWithoutTimeLeftToPutTheDisplayBack() async {
        let fake = FakeJump("t1")
        fake.surveys = [hidden]
        fake.trips = [arrived]
        fake.left = 0.05
        let report = await steps(fake)
        #expect(report.outcome == .abandoned)
        #expect(fake.calls == ["locate", "survey", "travel", "restore"])
        #expect(report.route.contains("out of time to look again"))
    }

    /// A survey after a trip is given the time left, and one cut short by it
    /// puts the display back.
    @Test func aSurveyCutShortWithADisplayMovedPutsItBack() async {
        let fake = FakeJump("t1")
        fake.surveys = [hidden, .cutShort]
        fake.trips = [arrived]
        fake.left = 1
        let report = await steps(fake)
        #expect(report.outcome == .abandoned)
        #expect(fake.surveyedWithin == [1.5, 1])
        #expect(fake.restored == [[home]])
        #expect(!fake.calls.contains("focus"))
    }

    /// With nothing moved, a survey that ran out of its own time is no answer:
    /// the jump focuses as it did before trips.
    @Test func aSurveyWithNoAnswerInTimeAndNothingMovedFocusesAsBefore() async {
        let fake = FakeJump("t1")
        fake.surveys = [.cutShort]
        let report = await steps(fake)
        #expect(report.outcome == .verified(reads: 0, focusAttempts: 1))
        #expect(fake.calls == ["locate", "survey", "focus"])
        #expect(report.route == "window not placed: Ghostty did not answer Accessibility in time")
    }

    @Test func withoutALockFileTheJumpFocusesAndTravelsNowhere() async {
        let fake = FakeJump("t1")
        fake.surveys = [hidden]
        fake.trips = [arrived]
        let report = await steps(fake, leased: false)
        #expect(report.outcome == .verified(reads: 0, focusAttempts: 1))
        #expect(fake.calls == ["locate", "focus"])
        #expect(report.route == "window not placed: no lock file to keep jumps apart")
    }

    /// A read of the selection that does not answer is no selection: the
    /// focus is tried once more and the jump ends unverified, in its time.
    @Test func aSelectionReadWithNoAnswerInTimeCountsAsNoSelection() async {
        let fake = FakeJump("t1")
        fake.focusSelects = "other"
        fake.selection = (10, "t1")
        let started = Date()
        let report = await steps(fake)
        #expect(report.outcome == .unverified(selected: nil, focusAttempts: 2))
        #expect(fake.calls == ["locate", "survey", "focus", "selected", "focus", "selected"])
        #expect(report.route.contains("selection not read in time"))
        #expect(Date().timeIntervalSince(started) < 3)
    }

    /// A jump whose read of the selection never answers still ends, and lets
    /// go of the lease: the next jump, waiting for it, gets it and runs.
    @Test func aStalledSelectionReadFreesTheLeaseForTheNextJump() async throws {
        let lease = scratchLease()
        defer { try? FileManager.default.removeItem(atPath: lease + ".flock") }
        let stuck = FakeJump("t1")
        stuck.focusSelects = "other"
        stuck.selection = (10, "t1")
        let next = FakeJump("t2")
        let limits = self.limits
        let started = Date()
        let first = Task {
            await TabJumpRun.run(
                "t1", leasePath: lease, leaseUntil: Date().addingTimeInterval(3), limits: limits,
                driver: stuck)
        }
        // The first jump holds the lease once it asks anything.
        while stuck.calls.isEmpty, Date().timeIntervalSince(started) < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(!stuck.calls.isEmpty, "the first jump never started")
        let second = await TabJumpRun.run(
            "t2", leasePath: lease, leaseUntil: Date().addingTimeInterval(3), limits: limits,
            driver: next)
        let firstReport = await first.value
        #expect(firstReport.outcome == .unverified(selected: nil, focusAttempts: 2))
        #expect(second.outcome == .verified(reads: 0, focusAttempts: 1))
        #expect(next.calls == ["locate", "survey", "focus"])
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func aJumpThatFindsAnotherUnderWayDoesNothing() async throws {
        let lease = scratchLease()
        defer { try? FileManager.default.removeItem(atPath: lease + ".flock") }
        let other = try #require(FileLease.acquire(lease))
        defer { other.release() }
        let fake = FakeJump("t1")
        let report = await TabJumpRun.run(
            "t1", leasePath: lease, leaseUntil: Date().addingTimeInterval(0.2), limits: limits,
            driver: fake)
        #expect(report.outcome == .busy)
        #expect(report.route == "another jump was still under way")
        #expect(fake.calls.isEmpty)
    }

    @Test func aJumpCancelledWhileItWaitsForAnotherIsAbandonedAtOnce() async throws {
        let lease = scratchLease()
        defer { try? FileManager.default.removeItem(atPath: lease + ".flock") }
        let other = try #require(FileLease.acquire(lease))
        defer { other.release() }
        let fake = FakeJump("t1")
        let limits = self.limits
        let started = Date()
        let jump = Task {
            await TabJumpRun.run(
                "t1", leasePath: lease, leaseUntil: Date().addingTimeInterval(5), limits: limits,
                driver: fake)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        jump.cancel()
        let report = await jump.value
        #expect(report.outcome == .abandoned)
        #expect(fake.calls.isEmpty)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// Quitting during a lookup after a trip: the lookup is cut short at once,
    /// and the display still goes back.
    @Test func aCancelledJumpCutsItsLookupShortAndStillPutsTheDisplayBack() async throws {
        let fake = FakeJump("t1")
        fake.lookups = [(0, .found(window: "w1")), (10, .found(window: "w1"))]
        fake.surveys = [hidden]
        fake.trips = [arrived]
        let limits = TabJumpRun.Limits(
            querySeconds: 5, cancelledSeconds: 0.05, leastLookupSeconds: 0.1)
        let started = Date()
        let jump = Task {
            await TabJumpRun.steps(
                TabJump(requested: "t1"), leased: true, limits: limits, driver: fake)
        }
        while fake.calls.filter({ $0 == "locate" }).count < 2, Date().timeIntervalSince(started) < 2
        {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        jump.cancel()
        let report = await jump.value
        #expect(report.outcome == .abandoned)
        #expect(fake.restored == [[home]])
        #expect(!fake.calls.contains("focus"))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func theLogLineSaysAJumpLeftAloneWasLeftAlone() {
        let report = TabJumpRun.Report(
            plan: TabJump(requested: "t1"), outcome: .busy,
            route: "another jump was still under way", accessibilityMissing: false)
        #expect(
            TabJumpRun.describe(report) == "jump: t1 left alone (another jump was still under way)")
    }
}
