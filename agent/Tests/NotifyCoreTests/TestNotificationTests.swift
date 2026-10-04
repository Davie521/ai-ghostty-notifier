import Foundation
import Testing

@testable import NotifyCore

@Suite struct TestNotificationTests {
    @Test func theRequestSurvivesTheSpoolAndKeepsItsTab() throws {
        let request = TestNotification.request(tabID: "tab-c0ffee")
        #expect(RequestCodec.isValidSessionID(request.sessionID))
        let decoded = try RequestCodec.decode(RequestCodec.encode(.notify(request)))
        #expect(decoded == .notify(request))
        #expect(request.tabID == "tab-c0ffee")
    }

    @Test func itStaysUntilClickedOrExpired() {
        let request = TestNotification.request(tabID: nil)
        // Run from the tab it points at; a clearing one would be gone in 3 s.
        #expect(request.clearOnFocus == false)
        #expect(request.timeout == TestNotification.timeout)
        #expect(request.sound != nil)
        #expect(request.title == AgentConstants.displayName)
    }

    @Test func aSecondTestReplacesTheFirst() {
        #expect(
            TestNotification.request(tabID: "a").sessionID
                == TestNotification.request(tabID: nil).sessionID)
    }

    /// What the agent does with each request, in Agent.handle(.notify).
    static func deliver(_ requests: [NotifyRequest]) -> SessionState {
        var state = SessionState()
        for request in requests {
            state.captureOwner(sessionID: request.stateKey, owner: request.owner)
            state.anchor(sessionID: request.stateKey, tabID: request.tabID, now: 1)
        }
        return state
    }

    @Test func aTestThatFoundNoTabDoesNotGoBackToTheLastOnes() {
        let state = Self.deliver([
            TestNotification.request(tabID: "tab-a"), TestNotification.request(tabID: nil),
        ])
        #expect(state.sessions[TestNotification.sessionID]?.tabID == nil)
    }

    @Test func aTestThatFoundATabGoesThere() {
        let state = Self.deliver([
            TestNotification.request(tabID: "tab-a"), TestNotification.request(tabID: "tab-b"),
        ])
        #expect(state.sessions[TestNotification.sessionID]?.tabID == "tab-b")
    }

    @Test func theReportSaysWhyThereIsNoTab() {
        #expect(TestNotification.sent(.tab).contains("the tab you ran this from"))
        #expect(TestNotification.sent(.ghosttyNotInFront).contains("Ghostty was not in front"))
        let unknown = TestNotification.sent(.tabUnknown)
        #expect(unknown.contains("did not say which tab"))
        #expect(unknown.contains("Automation"))
        #expect(!unknown.contains("not in front"))
    }

    @Test func onlyARunningAuthorizedAgentIsSentATest() {
        #expect(TestNotification.problem(running: true, readiness: "authorized") == nil)
        #expect(TestNotification.problem(running: false, readiness: "authorized") == .notRunning)
        #expect(
            TestNotification.problem(running: true, readiness: "denied")
                == .notAuthorized("denied"))
        #expect(TestNotification.problem(running: true, readiness: "") == .notAuthorized(""))
    }

    @Test func eachProblemSaysWhatToDo() {
        let app = "/Apps/X.app"
        #expect(TestNotification.explain(.notRunning, app: app).contains("open \"/Apps/X.app\""))
        #expect(
            TestNotification.explain(.notAuthorized("denied"), app: app)
                .contains("System Settings → Notifications"))
        #expect(
            TestNotification.explain(.notAuthorized(""), app: app).contains("no answer yet"))
        #expect(TestNotification.explain(.notCollected, app: app).contains("agent.log"))
    }
}
