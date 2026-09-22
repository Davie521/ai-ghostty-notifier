import Foundation
import Testing

@testable import NotifyCore

@Suite("Notification bookkeeping")
struct BookkeepingTests {
    // One stable identifier per session is what reproduces `-group
    // ghostty-notify-<session>`: re-adding a delivered identifier replaces it,
    // so a session that stops repeatedly leaves one banner, not a stack.
    @Test func theIdentifierIsStablePerSession() {
        var state = SessionState()
        let first = state.newNotification(sessionID: "abc", now: 1)
        let second = state.newNotification(sessionID: "abc", now: 2)
        let other = state.newNotification(sessionID: "def", now: 3)

        #expect(first == "claude-abc")
        #expect(second == first)
        #expect(other == "claude-def")
        // Re-posting must not double-track the same identifier, or a withdraw
        // would ask the center to remove it twice.
        #expect(state.sessions["abc"]?.notificationIDs == ["claude-abc"])
    }

    @Test func takingNotificationsClearsThemButKeepsTheTab() {
        var state = SessionState()
        state.anchor(sessionID: "abc", tabID: "TAB-1", now: 1)
        _ = state.newNotification(sessionID: "abc", now: 2)

        #expect(state.takeNotifications(sessionID: "abc") == ["claude-abc"])
        #expect(state.takeNotifications(sessionID: "abc") == [])
        // Losing the resolved tab would send the next focus event down the
        // app-level fallback path for a session we can actually localize.
        #expect(state.sessions["abc"]?.tabID == "TAB-1")
    }

    // A failed Apple Event query must not erase a tab we already know.
    @Test func anchoringWithNoTabDoesNotClearAKnownOne() {
        var state = SessionState()
        state.anchor(sessionID: "abc", tabID: "TAB-1", now: 1)
        state.anchor(sessionID: "abc", tabID: nil, now: 2)
        #expect(state.sessions["abc"]?.tabID == "TAB-1")
        state.anchor(sessionID: "abc", tabID: "", now: 3)
        #expect(state.sessions["abc"]?.tabID == "TAB-1")
    }

    @Test func anchoringRetargetsASessionThatMoved() {
        var state = SessionState()
        state.anchor(sessionID: "abc", tabID: "TAB-1", now: 1)
        state.anchor(sessionID: "abc", tabID: "TAB-2", now: 2)
        #expect(state.sessions["abc"]?.tabID == "TAB-2")
    }

    // The notification center removes a clicked notification itself, so the
    // agent only has to stop tracking it.
    @Test func forgettingAClickedNotification() {
        var state = SessionState()
        let id = state.newNotification(sessionID: "abc", now: 1)
        state.forgetNotification(id)
        #expect(state.sessions["abc"]?.notificationIDs == [])
        #expect(!state.hasOutstandingNotifications)
    }

    @Test func forgettingAnUnknownIdentifierIsHarmless() {
        var state = SessionState()
        let only = state.newNotification(sessionID: "abc", now: 1)
        state.forgetNotification("claude-nobody")
        #expect(state.sessions["abc"]?.notificationIDs == [only])
    }

    // A click has to route to a session even when the notification's payload is
    // unavailable — e.g. a banner posted by a previous version of the agent.
    @Test func anIdentifierCanBeTracedBackToItsSession() {
        var state = SessionState()
        let id = state.newNotification(sessionID: "abc", now: 1)
        #expect(state.sessionID(forNotification: id) == "abc")
        #expect(state.sessionID(forNotification: "claude-nobody") == nil)
    }

    @Test func aTimeoutSurvivesARestartAndAnOverdueOneIsCollected() throws {
        var state = SessionState()
        _ = state.newNotification(sessionID: "soon", now: 100)
        state.setExpiry(sessionID: "soon", at: 160)
        _ = state.newNotification(sessionID: "later", now: 100)
        state.setExpiry(sessionID: "later", at: 400)
        _ = state.newNotification(sessionID: "never", now: 100)
        // TIMEOUT=0: stays until focus, a prompt or a click.
        state.setExpiry(sessionID: "never", at: nil)
        // Nothing on screen, nothing to expire.
        state.anchor(sessionID: "idle", tabID: "TAB-1", now: 100)
        state.setExpiry(sessionID: "idle", at: 160)
        #expect(state.sessions["idle"]?.expiresAt == nil)

        // The agent goes down at 120 and comes back at 200.
        var restored = StateCodec.decode(try StateCodec.encode(state))
        #expect(restored == state)
        let resumed = restored.resumeExpiries(now: 200)
        #expect(resumed.overdue == ["claude-soon"])
        #expect(restored.sessions["soon"]?.expiresAt == nil)
        #expect(resumed.pending.map(\.identifier) == ["claude-later"])
        #expect(resumed.pending.first?.remaining == 200)
        #expect(restored.sessions["never"]?.notificationIDs == ["claude-never"])

        // A replacement notification does not inherit the old deadline.
        _ = restored.newNotification(sessionID: "later", now: 210)
        #expect(restored.resumeExpiries(now: 210).pending.isEmpty)
    }

    @Test func everyDeadlineIsEitherOverdueOrPendingWhateverTheMoment() {
        // Judged against one reading of the clock. With two, a deadline between
        // them was neither, and its notification kept no timer.
        for now in [159.999, 160, 160.001] {
            var state = SessionState()
            _ = state.newNotification(sessionID: "edge", now: 100)
            state.setExpiry(sessionID: "edge", at: 160)
            let resumed = state.resumeExpiries(now: now)
            #expect(resumed.overdue.count + resumed.pending.count == 1, "at \(now)")
            #expect(resumed.overdue.isEmpty == (now < 160), "at \(now)")
        }
    }

    @Test func stateWrittenBeforeDeadlinesExistedStillDecodes() {
        let old = Data(
            #"{"sessions":{"abc":{"notificationIDs":["claude-abc"],"updatedAt":5,"tabID":"T"}}}"#
                .utf8)
        let state = StateCodec.decode(old)
        #expect(state.sessions["abc"]?.tabID == "T")
        #expect(state.sessions["abc"]?.expiresAt == nil)
    }

    @Test func aLateTabAnswerDoesNotWithdrawWhatArrivedWhileItWasPending() {
        var state = SessionState()
        state.anchor(sessionID: "old", tabID: "TAB-1", now: 1)
        _ = state.newNotification(sessionID: "old", now: 10)
        let asked = state.outstanding()
        // The tab query is on its way. A round finishes in the same tab, and
        // another session replaces the notification it already had.
        state.anchor(sessionID: "new", tabID: "TAB-1", now: 11)
        _ = state.newNotification(sessionID: "new", now: 11)
        var replaced = state
        _ = replaced.newNotification(sessionID: "old", now: 12)

        let taken = state.takeNotifications(
            for: .ghosttyActivated(selectedTabID: "TAB-1"), among: asked)
        #expect(taken == ["claude-old"])
        #expect(state.sessions["new"]?.notificationIDs == ["claude-new"])
        #expect(
            replaced.takeNotifications(
                for: .ghosttyActivated(selectedTabID: "TAB-1"), among: asked) == [])
        // Without the snapshot the answer is applied to everything, which is
        // how a notification nobody had seen used to disappear.
        var unscoped = replaced
        #expect(
            unscoped.takeNotifications(for: .ghosttyActivated(selectedTabID: "TAB-1"))
                == ["claude-new", "claude-old"])
    }

    @Test func aLateDeliveredListDoesNotForgetWhatItCouldNotHaveListed() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "cleared", now: 10)
        _ = state.newNotification(sessionID: "just-posted", now: 99)
        // Asked at 100 with five seconds to settle: 99 is too new to judge.
        let asked = state.outstanding(postedBefore: 95)
        #expect(asked == ["cleared": 10])
        _ = state.newNotification(sessionID: "during", now: 100.5)

        let gone = state.forgetNotifications(notIn: [], among: asked)
        #expect(gone == ["claude-cleared"])
        #expect(state.sessions["just-posted"]?.notificationIDs == ["claude-just-posted"])
        #expect(state.sessions["during"]?.notificationIDs == ["claude-during"])
    }

    @Test func pruningDropsStaleSessionsAndReportsOrphans() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "old", now: 0)
        _ = state.newNotification(sessionID: "fresh", now: 100)

        let orphaned = state.prune(maxAge: 50, now: 100)
        #expect(orphaned == ["claude-old"])
        #expect(state.sessions.keys.sorted() == ["fresh"])
    }

    @Test func pruningKeepsSessionsExactlyAtTheBoundary() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "edge", now: 0)
        #expect(state.prune(maxAge: 50, now: 50) == [])
        #expect(state.sessions["edge"] != nil)
    }
}

@Suite("Dismissal on focus")
struct FocusDismissalTests {
    private func stateWithTwoSessions() -> SessionState {
        var state = SessionState()
        state.anchor(sessionID: "aaa", tabID: "TAB-1", now: 1)
        _ = state.newNotification(sessionID: "aaa", now: 1)
        state.anchor(sessionID: "bbb", tabID: "TAB-2", now: 1)
        _ = state.newNotification(sessionID: "bbb", now: 1)
        return state
    }

    @Test func anotherAppComingForwardDismissesNothing() {
        var state = stateWithTwoSessions()
        #expect(state.takeNotifications(for: .otherAppActivated) == [])
        #expect(state.sessions["aaa"]?.notificationIDs.isEmpty == false)
    }

    @Test func onlyTheSessionOnTheSelectedTabIsDismissed() {
        var state = stateWithTwoSessions()
        let dismissed = state.takeNotifications(for: .ghosttyActivated(selectedTabID: "TAB-1"))
        #expect(dismissed == ["claude-aaa"])
        // The other tab's notification is still waiting for its own tab.
        #expect(state.sessions["bbb"]?.notificationIDs == ["claude-bbb"])
    }

    // tmux and unscriptable-Ghostty sessions have no tab to match against;
    // Ghostty coming forward is the best evidence available that the user is
    // back, and this mirrors the app-level fallback the shell version had.
    @Test func aSessionWithNoKnownTabIsDismissedWheneverGhosttyComesForward() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "ccc", now: 1)
        #expect(
            state.takeNotifications(for: .ghosttyActivated(selectedTabID: "TAB-9"))
                == ["claude-ccc"])
    }

    // Losing the tab query is not evidence the user is on the right tab.
    // Clearing a localizable notification here would silently drop it.
    @Test func aFailedTabQueryLeavesLocalizedSessionsAlone() {
        var state = stateWithTwoSessions()
        _ = state.newNotification(sessionID: "ccc", now: 1)  // no tab

        let dismissed = state.takeNotifications(for: .ghosttyActivated(selectedTabID: nil))
        #expect(dismissed == ["claude-ccc"])
        #expect(state.sessions["aaa"]?.notificationIDs == ["claude-aaa"])
        #expect(state.sessions["bbb"]?.notificationIDs == ["claude-bbb"])
    }

    @Test func sessionsWithNothingOutstandingAreNotReported() {
        var state = stateWithTwoSessions()
        _ = state.takeNotifications(sessionID: "aaa")
        #expect(state.takeNotifications(for: .ghosttyActivated(selectedTabID: "TAB-1")) == [])
    }

    // GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0 is a documented opt-out for people who
    // keep completion notifications in Notification Center as a to-do list.
    // Focus must never withdraw one.
    @Test func aSessionThatOptedOutIsNeverWithdrawnByFocus() {
        var state = SessionState()
        state.anchor(sessionID: "keep", tabID: "TAB-1", now: 1)
        _ = state.newNotification(sessionID: "keep", clearOnFocus: false, now: 1)

        #expect(state.takeNotifications(for: .ghosttyActivated(selectedTabID: "TAB-1")) == [])
        #expect(state.sessions["keep"]?.notificationIDs == ["claude-keep"])
        // An explicit dismiss request is still honoured: that one is the user
        // (or the prompt hook) asking directly, not a focus side effect.
        #expect(state.takeNotifications(sessionID: "keep") == ["claude-keep"])
    }

    // The caller needs to know whether a (costly) Apple Event query is worth
    // issuing at all before paying for it.
    @Test func matchingCanBeAskedWithoutMutating() {
        let state = stateWithTwoSessions()
        #expect(state.sessionsMatching(selectedTabID: "TAB-1") == ["aaa"])
        #expect(state.sessionsMatching(selectedTabID: "TAB-404") == [])
        #expect(state.hasOutstandingNotifications)
    }

    // Reproduced on 2026-09-22: Ghostty frontmost throughout, the session's tab
    // selected five times for up to 25 seconds, and the notification stayed
    // until Ghostty was left and re-entered.
    @Test func switchingToTheSessionsTabInsideGhosttyWithdrawsIt() {
        var state = stateWithTwoSessions()
        #expect(state.takeNotifications(for: .ghosttyTabSelected(tabID: "TAB-1")) == ["claude-aaa"])
        #expect(state.sessions["bbb"]?.notificationIDs == ["claude-bbb"])
    }

    // Unlike activation, a switch is no evidence about a session that cannot be
    // placed in a tab: the user never left Ghostty. The fallback would take its
    // notification down about a second after posting.
    @Test func aTabSwitchLeavesASessionWithNoKnownTabAlone() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "ccc", now: 1)
        #expect(state.takeNotifications(for: .ghosttyTabSelected(tabID: "TAB-9")) == [])
        #expect(state.sessions["ccc"]?.notificationIDs == ["claude-ccc"])
    }

    @Test func aTabSwitchHonoursTheOptOut() {
        var state = SessionState()
        state.anchor(sessionID: "keep", tabID: "TAB-1", now: 1)
        _ = state.newNotification(sessionID: "keep", clearOnFocus: false, now: 1)
        #expect(state.takeNotifications(for: .ghosttyTabSelected(tabID: "TAB-1")) == [])
    }

    @Test func aLateSwitchAnswerDoesNotWithdrawWhatArrivedWhileItWasPending() {
        var state = stateWithTwoSessions()
        let asked = state.outstanding()
        _ = state.newNotification(sessionID: "aaa", now: 5)
        #expect(
            state.takeNotifications(for: .ghosttyTabSelected(tabID: "TAB-1"), among: asked) == [])
        #expect(state.sessions["aaa"]?.notificationIDs == ["claude-aaa"])
    }

    // Each poll of the selection is an Apple Event; with nothing a switch could
    // clear, the agent must not be asking at all.
    @Test func pollingIsOnlyWorthItForNotificationsOnKnownTabs() {
        var state = SessionState()
        #expect(!state.hasNotificationsOnKnownTabs)
        _ = state.newNotification(sessionID: "untabbed", now: 1)
        #expect(!state.hasNotificationsOnKnownTabs)
        state.anchor(sessionID: "kept", tabID: "TAB-1", now: 1)
        _ = state.newNotification(sessionID: "kept", clearOnFocus: false, now: 1)
        #expect(!state.hasNotificationsOnKnownTabs)
        state.anchor(sessionID: "tabbed", tabID: "TAB-2", now: 1)
        _ = state.newNotification(sessionID: "tabbed", now: 1)
        #expect(state.hasNotificationsOnKnownTabs)
        _ = state.takeNotifications(sessionID: "tabbed")
        #expect(!state.hasNotificationsOnKnownTabs)
    }
}

@Suite("Tab switches inside Ghostty")
struct TabSelectionWatchTests {
    // A notification posted onto the tab the user is watching gets a short
    // grace instead of vanishing; the poll that starts with it must not read
    // "they are on that tab" as "they just went there".
    @Test func theFirstAnswerIsOnlyABaseline() {
        var watch = TabSelectionWatch()
        #expect(watch.observe("TAB-1") == nil)
        #expect(watch.lastSeen == "TAB-1")
    }

    @Test func stayingOnATabIsNotASwitch() {
        var watch = TabSelectionWatch()
        _ = watch.observe("TAB-1")
        #expect(watch.observe("TAB-1") == nil)
    }

    @Test func movingReportsTheTabMovedTo() {
        var watch = TabSelectionWatch()
        _ = watch.observe("TAB-1")
        #expect(watch.observe("TAB-2") == "TAB-2")
        #expect(watch.observe("TAB-2") == nil)
        #expect(watch.observe("TAB-1") == "TAB-1")
    }

    @Test func aFailedQueryNeitherSwitchesNorForgets() {
        var watch = TabSelectionWatch()
        _ = watch.observe("TAB-1")
        #expect(watch.observe(nil) == nil)
        #expect(watch.observe("TAB-2") == "TAB-2")
    }

    @Test func leavingGhosttyStartsANewBaseline() {
        var watch = TabSelectionWatch()
        _ = watch.observe("TAB-1")
        watch.reset()
        #expect(watch.observe("TAB-2") == nil)
    }
}

@Suite("State persistence")
struct StatePersistenceTests {
    @Test func roundTripPreservesTabsAndOutstandingNotifications() throws {
        var state = SessionState()
        state.anchor(sessionID: "aaa", tabID: "TAB-1", now: 10)
        _ = state.newNotification(sessionID: "aaa", now: 11)
        _ = state.newNotification(sessionID: "bbb", now: 12)

        let restored = StateCodec.decode(try StateCodec.encode(state))
        #expect(restored.sessions["aaa"]?.tabID == "TAB-1")
        #expect(restored.sessions["aaa"]?.notificationIDs == ["claude-aaa"])
        #expect(restored.sessions["bbb"]?.notificationIDs == ["claude-bbb"])
    }

    // Restarting must not resurrect a notification the user opted to keep by
    // forgetting that it opted out.
    @Test func roundTripPreservesTheClearOnFocusOptOut() throws {
        var state = SessionState()
        _ = state.newNotification(sessionID: "keep", clearOnFocus: false, now: 1)
        var restored = StateCodec.decode(try StateCodec.encode(state))
        #expect(restored.sessions["keep"]?.clearOnFocus == false)
        #expect(restored.takeNotifications(for: .ghosttyActivated(selectedTabID: nil)) == [])
    }

    // State written before the opt-out existed has no such field; the
    // documented default is on.
    @Test func stateWithoutTheFieldDefaultsToClearing() {
        let json = #"{"sessions":{"aaa":{"notificationIDs":["claude-aaa"],"updatedAt":1}}}"#
        var restored = StateCodec.decode(Data(json.utf8))
        #expect(restored.sessions["aaa"]?.clearOnFocus == true)
        #expect(
            restored.takeNotifications(for: .ghosttyActivated(selectedTabID: nil))
                == ["claude-aaa"])
    }

    // Reposting after a restart must address the SAME notification, so the
    // banner that may still be on screen is replaced rather than duplicated.
    @Test func restoringKeepsTheIdentifierStable() throws {
        var state = SessionState()
        _ = state.newNotification(sessionID: "aaa", now: 1)

        var restored = StateCodec.decode(try StateCodec.encode(state))
        #expect(restored.newNotification(sessionID: "aaa", now: 2) == "claude-aaa")
        #expect(restored.sessions["aaa"]?.notificationIDs == ["claude-aaa"])
    }

    @Test(arguments: ["", "{", "null", #"{"sessions":"not a dict"}"#])
    func corruptStateStartsClean(_ text: String) {
        #expect(StateCodec.decode(Data(text.utf8)).sessions.isEmpty)
    }
}

@Suite("Paths")
struct PathsTests {
    @Test func everythingHangsOffHome() throws {
        let paths = try AgentPaths(env: ["HOME": "/tmp/sandbox"])
        let root = "/tmp/sandbox/.claude/notifications/ghostty-agent"
        #expect(paths.spool == root + "/spool")
        #expect(paths.state == root + "/state.json")
        #expect(paths.readyFile == root + "/ready")
        // Must match where ghostty-tab-save.sh writes, or the persisted tab id
        // can never be recovered after the agent loses its state.
        #expect(
            paths.sessionTabFile(sessionID: "abc")
                == "/tmp/sandbox/.claude/notifications/ghostty-sessions/abc.json")
    }

    @Test func missingHomeIsFatalRatherThanGuessed() {
        #expect(throws: AgentPathsError.missingHome) { try AgentPaths(env: [:]) }
        #expect(throws: AgentPathsError.missingHome) { try AgentPaths(env: ["HOME": ""]) }
    }
}
