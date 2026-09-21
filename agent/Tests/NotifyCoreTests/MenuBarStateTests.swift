import Foundation
import Testing

@testable import NotifyCore

@Suite("Menu bar state")
struct MenuBarStateTests {
    @Test func aChangeMadeInSystemSettingsReplacesTheLaunchTimeAnswer() {
        // Switched off while the agent runs: the hooks must stop routing to it.
        #expect(NotificationPermission.granted.updated(authorized: false) == .denied)
        #expect(NotificationPermission.denied.updated(authorized: true) == .granted)
        #expect(NotificationPermission.unknown.updated(authorized: true) == .granted)
        // Nothing on record is not an answer: what launch found stands.
        for known in [NotificationPermission.unknown, .granted, .denied, .unavailable] {
            #expect(known.updated(authorized: nil) == known)
        }
        #expect(NotificationPermission.granted.readiness == AgentConstants.readyAuthorized)
        #expect(NotificationPermission.denied.readiness == AgentConstants.readyDenied)
        #expect(NotificationPermission.unknown.readiness == nil)
        #expect(NotificationPermission.unavailable.readiness == nil)
    }

    @Test func anIdleAgentShowsNoNumber() {
        let state = MenuBarState.resolve(permission: .granted, alertStyle: "alert", waiting: 0)
        #expect(state == .idle)
        #expect(state.icon == .mark)
        // An empty badge is what gives the menu bar width back. A "0" would
        // claim space to say nothing.
        #expect(state.badgeText == "")
    }

    // The count is the signal; the mark stays the mark, so the icon is still
    // recognisable as this app at a glance.
    @Test func waitingSessionsAreCountedBesideTheSameMark() {
        let state = MenuBarState.resolve(permission: .granted, alertStyle: "alert", waiting: 3)
        #expect(state == .waiting(3))
        #expect(state.icon == .mark)
        #expect(state.badgeText == "3")
    }

    // The answer arrives asynchronously. Until it does the agent is presumed
    // working — a failure icon flashed during launch would train the user to
    // ignore it.
    @Test func anUnansweredPermissionIsNotAFailure() {
        #expect(
            MenuBarState.resolve(permission: .unknown, alertStyle: "", waiting: 0) == .idle)
        #expect(
            MenuBarState.resolve(permission: .unknown, alertStyle: "", waiting: 2) == .waiting(2))
    }

    // "The user said no" and "the system never asked" have opposite fixes: one
    // is permanent for this bundle identifier, the other clears on a relaunch.
    @Test func theTwoWaysAuthorizationFailsStayDistinct() {
        #expect(
            MenuBarState.resolve(permission: .denied, alertStyle: "alert", waiting: 0)
                == .problem(.notAuthorized, waiting: 0))
        #expect(
            MenuBarState.resolve(permission: .unavailable, alertStyle: "alert", waiting: 0)
                == .problem(.authorizationUnavailable, waiting: 0))
    }

    @Test func alertsTurnedOffIsAProblemAndTemporaryAlertsAreNot() {
        #expect(
            MenuBarState.resolve(permission: .granted, alertStyle: "none", waiting: 1)
                == .problem(.alertsOff, waiting: 1))
        // Banner still delivers; it only slides away. A permanent warning glyph
        // for a state that never resolves would drown the count the icon exists
        // to carry, so it is reported in the menu instead.
        #expect(
            MenuBarState.resolve(permission: .granted, alertStyle: "banner", waiting: 1)
                == .waiting(1))
    }

    // A problem leads the icon, but the count must not be lost with it: those
    // sessions are still waiting, and the menu still lists them.
    @Test func aProblemKeepsTheWaitingCount() {
        let state = MenuBarState.resolve(permission: .denied, alertStyle: "alert", waiting: 2)
        #expect(state.icon == .markCrossedOut)
        #expect(state.badgeText == "2")
    }

    @Test func everyStateDescribesItselfForVoiceOver() {
        for state: MenuBarState in [
            .idle, .waiting(1), .waiting(4), .problem(.notAuthorized, waiting: 0),
            .problem(.authorizationUnavailable, waiting: 1), .problem(.alertsOff, waiting: 0),
        ] {
            #expect(!state.accessibilityDescription.isEmpty)
        }
    }

    // The label set on the status button overrides the visible count, so a
    // description that omitted it would tell a VoiceOver user nothing is
    // waiting while the badge says two.
    @Test func theSpokenLabelNeverContradictsTheBadge() {
        for state: MenuBarState in [
            .waiting(2), .problem(.notAuthorized, waiting: 2),
            .problem(.authorizationUnavailable, waiting: 2), .problem(.alertsOff, waiting: 2),
        ] {
            #expect(state.badgeText == "2")
            #expect(state.accessibilityDescription.contains("2 sessions waiting"))
        }
        // …and says nothing about a count when there is none to report.
        #expect(
            !MenuBarState.problem(.notAuthorized, waiting: 0)
                .accessibilityDescription.contains("waiting"))
    }
}

@Suite("Waiting session rows")
struct WaitingSessionTests {
    private func session(
        id: String = "abc", title: String = "Claude ✅", subtitle: String = "refactor — cgn",
        body: String = "Finished after 5m 3s", postedAt: Double = 0
    ) -> WaitingSession {
        WaitingSession(
            sessionID: id, title: title, subtitle: subtitle, body: body, postedAt: postedAt)
    }

    // The row stands in for a notification the user may have missed, so it says
    // what the notification said — same text, same order, nothing re-worded.
    @Test func theRowIsTheNotificationVerbatim() {
        #expect(
            session().notificationLines() == [
                NotificationLine(role: .title, text: "Claude ✅"),
                NotificationLine(role: .subtitle, text: "refactor — cgn"),
                NotificationLine(role: .body, text: "Finished after 5m 3s"),
            ])
    }

    // macOS drops an empty subtitle rather than leaving a gap; so does the row.
    @Test func emptyLinesAreDroppedRatherThanShownBlank() {
        #expect(
            session(subtitle: "  ", body: "").notificationLines() == [
                NotificationLine(role: .title, text: "Claude ✅")
            ])
        #expect(session(title: "", subtitle: "", body: "").notificationLines() == [])
    }

    // Each surviving line keeps its role. Styling by position would render a
    // body as a subtitle the moment an empty subtitle is dropped ahead of it.
    @Test func aDroppedSubtitleDoesNotPromoteTheBody() {
        let lines = session(subtitle: "").notificationLines()
        #expect(lines.map(\.role) == [.title, .body])
        #expect(lines.last?.text == "Finished after 5m 3s")
    }

    // The phrasing is Notification Center's, for the same reason the text is:
    // the row and the notification must not describe the same moment
    // differently.
    @Test func theTimeIsPhrasedTheWayNotificationCenterPhrasesIt() {
        let posted = session(postedAt: 1000)
        #expect(posted.relativeTime(now: 1000) == "now")
        #expect(posted.relativeTime(now: 1059) == "now")
        #expect(posted.relativeTime(now: 1060) == "1m ago")
        #expect(posted.relativeTime(now: 1000 + 59 * 60) == "59m ago")
        #expect(posted.relativeTime(now: 1000 + 3600) == "1h ago")
        #expect(posted.relativeTime(now: 1000 + 25 * 3600) == "1d ago")
        // Clock skew between posting and reading must not print "-3m ago".
        #expect(posted.relativeTime(now: 900) == "now")
    }

    // Clipped, not wrapped — a menu is not the place to reflow a session title,
    // and a notification clips it too.
    @Test func longLinesAreClipped() {
        let long = String(repeating: "x", count: 120)
        let lines = session(subtitle: long).notificationLines()
        #expect(lines[1].text.count == 64)
        #expect(lines[1].text.hasSuffix("…"))
        // Only the long line is touched.
        #expect(lines[0].text == "Claude ✅")
    }

    // State written before the text was recorded leaves a row with nothing to
    // say. It still has to be visible: the session is waiting on the user.
    @Test func aRowWithNoTextStillNamesItsSession() {
        #expect(
            session(id: "0123456789ab", title: "", subtitle: "", body: "").fallbackLabel
                == "Session 01234567")
    }
}

@Suite("Notification text is not kept once it is off screen")
struct NoticeLifetimeTests {
    // The text is the user's session title, their project folder and whatever
    // Claude was asking — none of which reached disk before the menu needed it.
    // The record survives dismissal by up to 24h so its tab is not lost; the
    // text has no reason to ride along.
    @Test func takingNotificationsClearsTheText() {
        var state = SessionState()
        state.anchor(sessionID: "abc", tabID: "TAB-1", now: 1)
        _ = state.newNotification(
            sessionID: "abc", title: "Claude ✅", subtitle: "private thing — secret-project",
            body: "Finished after 5m 3s", now: 2)

        _ = state.takeNotifications(sessionID: "abc")

        #expect(state.sessions["abc"]?.subtitle == "")
        #expect(state.sessions["abc"]?.body == "")
        #expect(state.sessions["abc"]?.title == "")
        #expect(state.sessions["abc"]?.postedAt == 0)
        // …but the tab, which is the reason the record outlives the
        // notification, is untouched.
        #expect(state.sessions["abc"]?.tabID == "TAB-1")
    }

    @Test func aClickedNotificationClearsItsTextToo() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "abc", subtitle: "private thing", now: 2)
        state.forgetNotification("claude-abc")
        #expect(state.sessions["abc"]?.subtitle == "")
    }
}

@Suite("Reconciling with the notification center")
struct ReconcileTests {
    // The user can clear a notification from Notification Center — most
    // invisibly with a "Clear All" while the agent is not running. Bookkeeping
    // that outlives the notification used to be unobservable; with a count on
    // the menu bar it is a standing lie.
    @Test func identifiersNoLongerOnScreenAreForgotten() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "gone", subtitle: "stale", now: 1)
        _ = state.newNotification(sessionID: "live", subtitle: "real", now: 2)

        let dropped = state.forgetNotifications(notIn: ["claude-live"])

        #expect(dropped == ["claude-gone"])
        #expect(state.waitingCount == 1)
        #expect(state.waitingSessions().map(\.sessionID) == ["live"])
        // Its text goes with it.
        #expect(state.sessions["gone"]?.subtitle == "")
    }

    @Test func reconcilingChangesNothingWhenEverythingIsStillOnScreen() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "abc", now: 1)
        #expect(state.forgetNotifications(notIn: ["claude-abc"]) == [])
        #expect(state.waitingCount == 1)
    }

    @Test func theCheapCountAgreesWithTheRows() {
        var state = SessionState()
        state.anchor(sessionID: "quiet", tabID: "TAB-1", now: 1)
        _ = state.newNotification(sessionID: "one", now: 2)
        _ = state.newNotification(sessionID: "two", now: 3)

        #expect(state.waitingCount == state.waitingSessions().count)
        #expect(state.waitingCount == 2)
    }
}

@Suite("Waiting sessions from bookkeeping")
struct WaitingSessionListTests {
    @Test func onlySessionsWithSomethingOnScreenAreListed() {
        var state = SessionState()
        state.anchor(sessionID: "quiet", tabID: "TAB-1", now: 1)
        _ = state.newNotification(
            sessionID: "loud", subtitle: "fix CI — moneytalk", now: 2)

        let waiting = state.waitingSessions()
        #expect(waiting.map(\.sessionID) == ["loud"])
        #expect(waiting.first?.subtitle == "fix CI — moneytalk")
    }

    // Newest first, and a deterministic tie-break: the rows are click targets,
    // so a menu that reorders itself between two openings is worse than a stale
    // one.
    @Test func rowsAreNewestFirstAndTiesAreStable() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "old", now: 10)
        _ = state.newNotification(sessionID: "new", now: 30)
        _ = state.newNotification(sessionID: "bbb", now: 20)
        _ = state.newNotification(sessionID: "aaa", now: 20)

        #expect(state.waitingSessions().map(\.sessionID) == ["new", "aaa", "bbb", "old"])
    }

    // A replacement notification reuses the identifier, which is exactly why the
    // text it replaces must not survive: the row would name the previous round.
    @Test func aReplacementNotificationReplacesTheRowText() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "abc", subtitle: "first", now: 10)
        _ = state.newNotification(sessionID: "abc", subtitle: "second", now: 40)

        let row = state.waitingSessions().first
        #expect(row?.subtitle == "second")
        #expect(row?.postedAt == 40)
    }

    // An anchor moves `updatedAt` without anything new appearing, so the age in
    // the menu has to come from its own timestamp.
    @Test func anchoringDoesNotMakeANotificationLookFresh() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "abc", now: 10)
        state.anchor(sessionID: "abc", tabID: "TAB-9", now: 900)

        #expect(state.waitingSessions().first?.postedAt == 10)
    }
}

@Suite("State file compatibility")
struct StateCompatibilityTests {
    @Test func theNewFieldsSurviveARoundTrip() throws {
        var state = SessionState()
        state.anchor(sessionID: "abc", tabID: "TAB-1", now: 5)
        _ = state.newNotification(
            sessionID: "abc", title: "Claude ✅", subtitle: "refactor — cgn",
            body: "Finished after 5m 3s", now: 42)

        let restored = StateCodec.decode(try StateCodec.encode(state))
        let row = try #require(restored.waitingSessions().first)
        #expect(row.title == "Claude ✅")
        #expect(row.subtitle == "refactor — cgn")
        #expect(row.body == "Finished after 5m 3s")
        #expect(row.postedAt == 42)
        #expect(restored.sessions["abc"]?.tabID == "TAB-1")
    }

    // State written by an older agent has none of these fields. Failing to
    // decode it would throw away every session's resolved tab id, which is what
    // click-to-jump runs on.
    @Test func stateWrittenBeforeTheseFieldsExistedStillDecodes() throws {
        let legacy = """
            {"sessions":{"abc":{"tabID":"TAB-1","notificationIDs":["claude-abc"],\
            "clearOnFocus":true,"updatedAt":900}}}
            """
        let restored = StateCodec.decode(Data(legacy.utf8))

        #expect(restored.sessions["abc"]?.tabID == "TAB-1")
        let row = try #require(restored.waitingSessions().first)
        // No posted time was recorded, so it is backfilled from `updatedAt`
        // rather than claiming the notification arrived in 1970.
        #expect(row.postedAt == 900)
        // No text was recorded either, so the row falls back to naming the
        // session rather than rendering as an empty menu item.
        #expect(row.notificationLines().isEmpty)
        #expect(row.fallbackLabel == "Session abc")
    }

    // The backfill happens once, at restore. Resolving it on every read instead
    // would reintroduce the bug `postedAt` exists to prevent: an anchor moves
    // `updatedAt`, so the next prompt submitted anywhere would make an
    // hours-old notification start reporting itself as "now".
    @Test func aRestoredLegacyRowDoesNotGetYoungerWhenTheSessionIsAnchored() {
        let legacy = """
            {"sessions":{"abc":{"tabID":"TAB-1","notificationIDs":["claude-abc"],\
            "clearOnFocus":true,"updatedAt":900}}}
            """
        var restored = StateCodec.decode(Data(legacy.utf8))
        restored.anchor(sessionID: "abc", tabID: "TAB-2", now: 100_000)

        #expect(restored.waitingSessions().first?.postedAt == 900)
        #expect(restored.waitingSessions().first?.relativeTime(now: 100_000) != "now")
    }
}

@Suite("Menu status block")
struct MenuStatusBlockTests {
    // Two ticks saying the same "fine" only pushed the sessions down.
    @Test func everythingInOrderIsOneQuietLine() {
        let block = MenuStatusLine.block(permission: .granted, alertStyle: "alert")
        #expect(block == [MenuStatusLine(tone: .ok, text: "Notifications on · Persistent")])
    }

    // The first seconds after launch, before either answer is back.
    @Test func twoPendingAnswersAreOneCheckingLine() {
        let block = MenuStatusLine.block(permission: .unknown, alertStyle: "")
        #expect(block.map(\.tone) == [.checking])
        #expect(block.first?.opensSettings == false)
    }

    // Only the part still pending is reported as pending; the part already in
    // order is not repeated beside it.
    @Test func onlyTheOpenPartIsReported() {
        #expect(
            MenuStatusLine.block(permission: .granted, alertStyle: "").map(\.text)
                == ["Checking alert style…"])
        #expect(
            MenuStatusLine.block(permission: .unknown, alertStyle: "alert").map(\.text)
                == ["Checking notification permission…"])
    }

    // A problem is its own line, never folded into a summary — and a pending
    // answer beside it is not merged away with it.
    @Test func aProblemIsNotFoldedIntoAPendingAnswer() {
        let block = MenuStatusLine.block(permission: .unknown, alertStyle: "banner")
        #expect(block.map(\.tone) == [.checking, .problem])
    }

    // macOS reports "none" for a denied app. Two warnings with two different
    // fixes for one problem would send the user looking for the second.
    @Test func withoutPermissionTheAlertStyleIsNotReported() {
        for permission in [NotificationPermission.denied, .unavailable] {
            for style in ["none", "banner", "alert", ""] {
                let block = MenuStatusLine.block(permission: permission, alertStyle: style)
                #expect(block.count == 1)
                #expect(block.first?.tone == .problem)
            }
        }
    }

    // Clickable exactly where System Settings holds the fix. A disabled item is
    // drawn dimmed, like "fine", so every fixable problem has to be a button —
    // and the one Settings cannot fix must not pretend to be.
    @Test func problemsAreButtonsExactlyWhereSettingsHoldsTheFix() {
        #expect(
            MenuStatusLine.block(permission: .denied, alertStyle: "none").first?.opensSettings
                == true)
        #expect(
            MenuStatusLine.block(permission: .granted, alertStyle: "banner").first?.opensSettings
                == true)
        #expect(
            MenuStatusLine.block(permission: .granted, alertStyle: "none").first?.opensSettings
                == true)
        #expect(
            MenuStatusLine.block(permission: .unavailable, alertStyle: "").first?.opensSettings
                == false)
    }

    // Temporary still delivers, so the icon leaves it alone; the menu is where
    // it is reported.
    @Test func temporaryAlertsAreReportedInTheMenu() {
        let block = MenuStatusLine.block(permission: .granted, alertStyle: "banner")
        #expect(
            block == [
                MenuStatusLine(
                    tone: .problem, text: "Alert style: Temporary — Fix…", opensSettings: true)
            ])
    }

    // An answer this build cannot judge is not "checking": that would claim one
    // is still on its way, forever.
    @Test func anUnknownStyleIsNamedNotAwaited() {
        let block = MenuStatusLine.block(permission: .granted, alertStyle: "unknown")
        #expect(block == [MenuStatusLine(tone: .unrecognised, text: "Alert style: unknown")])
    }

    @Test func theSmallPrintCountsSessions() {
        #expect(MenuText.sessionsSeen(1) == "1 session seen in the last 24h")
        #expect(MenuText.sessionsSeen(45) == "45 sessions seen in the last 24h")
        #expect(MenuText.sessionsSeen(0) == "0 sessions seen in the last 24h")
        #expect(MenuText.waitingHeader(3) == "Waiting · 3")
    }
}

@Suite("Waiting rows as the menu lays them out")
struct WaitingRowLayoutTests {
    private func session(
        id: String = "abc", title: String = "Claude", subtitle: String = "refactor — cgn",
        body: String = "Finished after 5m 3s", postedAt: Double = 1000
    ) -> WaitingSession {
        WaitingSession(
            sessionID: id, title: title, subtitle: subtitle, body: body, postedAt: postedAt)
    }

    // Same lines, same order as the notification; the time rides on the title.
    @Test func theTimeRidesOnTheTitle() {
        #expect(
            session().menuLines(now: 1000 + 5 * 60) == [
                NotificationLine(role: .title, text: "Claude · 5m ago"),
                NotificationLine(role: .subtitle, text: "refactor — cgn"),
                NotificationLine(role: .body, text: "Finished after 5m 3s"),
            ])
    }

    // With no title to ride on, the time still gets a line of its own.
    @Test func aRowWithoutATitleStillSaysWhen() {
        let lines = session(title: "").menuLines(now: 1000)
        #expect(lines.first == NotificationLine(role: .title, text: "now"))
        #expect(lines.map(\.role) == [.title, .subtitle, .body])
    }

    // No text at all: the row names its session, where the eye goes first.
    @Test func aRowWithNoTextNamesItsSession() {
        let lines = session(id: "0123456789ab", title: "", subtitle: "", body: "")
            .menuLines(now: 1000)
        #expect(
            lines == [
                NotificationLine(role: .title, text: "now"),
                NotificationLine(role: .subtitle, text: "Session 01234567"),
            ])
    }

    // A tooltip only where the row was clipped, carrying the whole text.
    @Test func theTooltipIsForClippedRowsOnly() {
        #expect(session().clippedText() == nil)
        let long = String(repeating: "x", count: 120)
        #expect(
            session(subtitle: long).clippedText()
                == "Claude\n\(long)\nFinished after 5m 3s")
    }
}
