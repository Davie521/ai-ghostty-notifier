import Foundation
import Testing

@testable import NotifyCore

@Suite struct NudgeNotificationTests {
    static let session = "99de3170-08b4-48ec-a7c3-845e6b4de565"

    static func request(
        title: String = "", project: String = "repo", tabID: String? = "tab-1",
        roundID: String? = "round-1", settings: [String: String] = [:]
    ) -> NotifyRequest {
        NudgeNotification.request(
            sessionID: session, message: "Face ID on your phone", title: title,
            project: project, tabID: tabID, roundID: roundID, settings: settings)
    }

    static let thread = "01a1974d-5956-7ad1-9c87-b3ffeffb8fd8"

    @Test func theSessionIsTheOneTheCLIRunsTheCommandFor() {
        let claude = NudgeNotification.Session(id: Self.session, source: .claude)
        let codex = NudgeNotification.Session(id: Self.thread, source: .codex)
        #expect(
            NudgeNotification.session(environment: ["CLAUDE_CODE_SESSION_ID": Self.session])
                == claude)
        #expect(NudgeNotification.session(environment: ["CODEX_THREAD_ID": Self.thread]) == codex)
        #expect(NudgeNotification.session(environment: [:]) == nil)
        #expect(NudgeNotification.session(environment: ["CLAUDE_CODE_SESSION_ID": ""]) == nil)
        // Becomes a file name under the session directory.
        #expect(
            NudgeNotification.session(environment: ["CLAUDE_CODE_SESSION_ID": "../x"]) == nil)
        #expect(NudgeNotification.session(environment: ["CODEX_THREAD_ID": "a/b"]) == nil)
    }

    /// Codex run inside Claude Code inherits Claude's variable, and the other
    /// way round: the CLI nearest above the command is the one asking.
    @Test func withBothSetTheNearestCLIDecides() {
        let both = ["CLAUDE_CODE_SESSION_ID": Self.session, "CODEX_THREAD_ID": Self.thread]
        #expect(NudgeNotification.session(environment: both, nearest: .codex)?.source == .codex)
        #expect(NudgeNotification.session(environment: both, nearest: .claude)?.source == .claude)
        #expect(NudgeNotification.session(environment: both)?.source == .claude)
        // A malformed one does not hide the other.
        let broken = ["CLAUDE_CODE_SESSION_ID": "../x", "CODEX_THREAD_ID": Self.thread]
        #expect(NudgeNotification.session(environment: broken, nearest: .claude)?.id == Self.thread)
    }

    @Test func aCodexNudgeIsCodexsOwnNotification() throws {
        let request = NudgeNotification.request(
            sessionID: Self.thread, source: .codex, message: "Scan the QR code", title: "",
            project: "repo", tabID: nil, roundID: nil, settings: [:])
        #expect(request.source == .codex)
        #expect(request.stateKey == "codex-" + Self.thread)
        #expect(request.title == "Codex")
        #expect(try RequestCodec.decode(RequestCodec.encode(.notify(request))) == .notify(request))
    }

    @Test func theMessageIsOneBoundedLine() {
        #expect(NudgeNotification.message(["Scan", "the  QR\ncode"]) == "Scan the QR code")
        #expect(NudgeNotification.message(["a\u{1b}[31mb"]) == "a[31mb")
        #expect(NudgeNotification.message([]) == nil)
        #expect(NudgeNotification.message(["  ", "\n"]) == nil)
        let long = NudgeNotification.message([String(repeating: "码", count: 500)])
        #expect(long?.count == NudgeNotification.maximumLength)
        #expect(long?.hasSuffix("…") == true)
        let exact = String(repeating: "x", count: NudgeNotification.maximumLength)
        #expect(NudgeNotification.message([exact]) == exact)
    }

    @Test func itIsTheSessionsOwnNotificationAndSurvivesTheSpool() throws {
        let request = Self.request(title: "Bank login")
        #expect(request.sessionID == Self.session)
        #expect(request.stateKey == Self.session)
        #expect(request.source == .claude)
        #expect(request.title == "Claude")
        #expect(request.subtitle == "Bank login — repo")
        #expect(request.body == "Face ID on your phone")
        #expect(request.tabID == "tab-1")
        #expect(request.roundID == "round-1")
        #expect(try RequestCodec.decode(RequestCodec.encode(.notify(request))) == .notify(request))
    }

    @Test func itIsSilentUnlessNudgeSoundIsOn() {
        #expect(Self.request().sound == nil)
        #expect(Self.request(settings: ["GHOSTTY_NOTIFY_SOUND_ELAPSED": "0"]).sound == nil)
        #expect(Self.request(settings: ["GHOSTTY_NOTIFY_NUDGE_SOUND": "0"]).sound == nil)
        #expect(Self.request(settings: ["GHOSTTY_NOTIFY_NUDGE_SOUND": "1"]).sound == "Ping")
        #expect(Self.request(settings: ["GHOSTTY_NOTIFY_NUDGE_SOUND": "On"]).sound == "Ping")
    }

    @Test func anUntitledSessionSaysItNeedsYou() {
        #expect(Self.request().subtitle == "Needs You — repo")
        #expect(Self.request(project: "").subtitle == "Needs You")
    }

    @Test func itFollowsTheSessionsSettings() {
        let defaults = Self.request()
        #expect(defaults.timeout == 1200)
        #expect(defaults.clearOnFocus)
        let set = Self.request(settings: [
            "GHOSTTY_NOTIFY_TIMEOUT": "0", "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "0",
            "GHOSTTY_NOTIFY_APP_NAME": "Claude Code",
        ])
        #expect(set.timeout == nil)
        #expect(!set.clearOnFocus)
        #expect(set.title == "Claude Code")
    }

    @Test func aMissingTabOrRoundIsSentAsNone() {
        let request = Self.request(tabID: "", roundID: "")
        #expect(request.tabID == nil)
        #expect(request.roundID == nil)
    }

    /// What Agent.handle(.notify) does with the session it is sent for.
    @Test func itKeepsTheTabTheSessionsHooksBound() {
        var state = SessionState()
        state.captureOwner(sessionID: Self.session, owner: "82749:ttys009:1793530800.7")
        state.anchor(sessionID: Self.session, tabID: "tab-bound", now: 1)
        let nudge = Self.request(tabID: nil)
        state.captureOwner(sessionID: nudge.stateKey, owner: nudge.owner)
        state.anchor(sessionID: nudge.stateKey, tabID: nudge.tabID, now: 2)
        #expect(state.sessions[Self.session]?.tabID == "tab-bound")
    }

    @Test func theNextPromptWithdrawsIt() {
        var state = SessionState()
        let nudge = Self.request()
        let id = state.newNotification(
            sessionID: nudge.stateKey, now: 1, roundID: nudge.roundID)
        #expect(
            state.takePreviousRoundNotifications(sessionID: Self.session, roundID: "round-2")
                == [id])
    }

    @Test func eachProblemSaysNothingWasSentAndWhatToDo() {
        let app = "/Apps/X.app"
        let none = NudgeNotification.explain(.noSession, app: app)
        #expect(none.contains("CLAUDE_CODE_SESSION_ID"))
        #expect(none.contains("CODEX_THREAD_ID"))
        #expect(none.contains("nothing was sent"))
        let sandboxed = NudgeNotification.explain(.notCollectedFromSandbox, app: app)
        #expect(sandboxed.contains("taken back and nothing was sent"))
        #expect(sandboxed.contains("0.9.0"))
        let stopped = NudgeNotification.explain(.agent(.notRunning), app: app)
        #expect(stopped.contains("nothing was sent"))
        #expect(stopped.contains("open \"/Apps/X.app\""))
        #expect(!stopped.contains("test"))
        #expect(
            NudgeNotification.explain(.agent(.notAuthorized("denied")), app: app)
                .contains("System Settings → Notifications"))
        // Not taken within five seconds, so taken back: nothing will appear.
        let late = NudgeNotification.explain(.agent(.notCollected), app: app)
        #expect(late.contains("taken back and nothing was sent"))
        #expect(late.contains("agent.log"))
        // The one case where something may still appear says so.
        let stuck = NudgeNotification.explain(.stuck("Permission denied"), app: app)
        #expect(stuck.contains("may still appear later"))
        #expect(stuck.contains("Permission denied"))
        #expect(!stuck.contains("nothing was sent"))
    }

    @Test func theTestKeepsItsOwnWording() {
        let app = "/Apps/X.app"
        #expect(TestNotification.explain(.notRunning, app: app).contains("no test was sent"))
        #expect(
            TestNotification.explain(.notCollected, app: app).hasPrefix("The test was queued"))
    }

    @Test func theReportSaysWhereGoToTabLeads() {
        #expect(NudgeNotification.sent(tabKnown: true).contains("this session's tab"))
        #expect(NudgeNotification.sent(tabKnown: false).contains("only brings Ghostty forward"))
        #expect(
            NudgeNotification.sent(tabKnown: true, noReturn: true).contains("--nudge-done"))
    }

    /// The flag only counts in front; a message mentioning it is said in full.
    @Test func noReturnIsAFlagInFrontOfTheMessage() {
        #expect(
            NudgeNotification.parse(["--no-return", "Slide", "it"]) == (true, ["Slide", "it"]))
        #expect(
            NudgeNotification.parse(["Slide", "--no-return"]) == (false, ["Slide", "--no-return"]))
        #expect(NudgeNotification.parse([]) == (false, []))
        #expect(NudgeNotification.parse(["--no-return"]) == (true, []))
    }

    @Test func aNudgeIsMarkedAsOneAndKeepsGoToTabByDefault() throws {
        let request = Self.request()
        #expect(request.nudge)
        #expect(!request.noReturn)
        #expect(request.timeout == 1200)  // GHOSTTY_NOTIFY_TIMEOUT's default
        let decoded = try RequestCodec.decode(RequestCodec.encode(.notify(request)))
        #expect(decoded == .notify(request))
    }

    /// Nobody comes back to the tab to clear it, so it goes by itself, sooner
    /// still when the user set a shorter timeout.
    @Test func aNoReturnNudgeGoesByItself() throws {
        func request(_ settings: [String: String]) -> NotifyRequest {
            NudgeNotification.request(
                sessionID: Self.session, message: "Slide the captcha on the 12 mini", title: "",
                project: "repo", tabID: "tab-1", roundID: nil, settings: settings,
                noReturn: true)
        }
        let plain = request([:])
        #expect(plain.noReturn && plain.nudge)
        #expect(plain.timeout == NudgeNotification.noReturnSeconds)
        #expect(request(["GHOSTTY_NOTIFY_TIMEOUT": "60"]).timeout == 60)
        #expect(
            request(["GHOSTTY_NOTIFY_TIMEOUT": "3600"]).timeout
                == NudgeNotification.noReturnSeconds)
        #expect(try RequestCodec.decode(RequestCodec.encode(.notify(plain))) == .notify(plain))
    }

    @Test func takingANudgeBackSurvivesTheSpool() throws {
        let claude = AgentRequest.dismissNudge(sessionID: Self.session)
        let codex = AgentRequest.dismissNudge(sessionID: Self.thread, source: .codex)
        #expect(try RequestCodec.decode(RequestCodec.encode(claude)) == claude)
        #expect(try RequestCodec.decode(RequestCodec.encode(codex)) == codex)
    }

    /// `--nudge-done` must not take back the run's completion notification,
    /// which replaces the nudge under the same identifier.
    @Test func onlyANudgeIsTakenBack() {
        var state = SessionState()
        let id = state.newNotification(sessionID: Self.session, now: 1, nudge: true)
        #expect(state.takeNudge(sessionID: Self.session) == [id])
        #expect(state.takeNudge(sessionID: Self.session) == [])

        _ = state.newNotification(sessionID: Self.session, now: 2, nudge: true)
        _ = state.newNotification(sessionID: Self.session, now: 3)
        #expect(state.takeNudge(sessionID: Self.session) == [])
        #expect(state.sessions[Self.session]?.notificationIDs == [id])
    }

    @Test func whetherItIsANudgeOutlivesARestart() throws {
        var state = SessionState()
        _ = state.newNotification(sessionID: Self.session, now: 1, nudge: true)
        _ = state.newNotification(sessionID: Self.thread, now: 1)
        let restored = StateCodec.decode(try StateCodec.encode(state))
        #expect(restored.sessions[Self.session]?.nudge == true)
        #expect(restored.sessions[Self.thread]?.nudge == false)
        // State an older agent wrote has no such field.
        let old = Data(
            #"{"sessions":{"\#(Self.session)":{"notificationIDs":["x"],"updatedAt":1}}}"#.utf8)
        #expect(StateCodec.decode(old).sessions[Self.session]?.nudge == false)
    }
}
