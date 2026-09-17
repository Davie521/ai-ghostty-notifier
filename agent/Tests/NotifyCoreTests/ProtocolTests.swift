import Foundation
import Testing

@testable import NotifyCore

@Suite("Session id validation")
struct SessionIDTests {
    @Test(arguments: [
        "deadbeef-1234-5678-9abc-def012345678",
        "abc123",
        "----",
        "0",
    ])
    func accepted(_ id: String) {
        #expect(RequestCodec.isValidSessionID(id))
    }

    // Session ids become dictionary keys and are embedded in notification
    // identifiers; separators and non-hex bytes have no business there.
    @Test(arguments: [
        "",
        "../escape",
        "has space",
        "semi;colon",
        "zz-not-hex",
        "unicode-é",
        "ａｂｃ-１２３",
        "ＡＢＣ",
        "١٢٣",
    ])
    func rejected(_ id: String) {
        #expect(!RequestCodec.isValidSessionID(id))
    }
}

@Suite("Request decoding")
struct RequestDecodingTests {
    private func decode(_ json: String) throws -> AgentRequest {
        try RequestCodec.decode(Data(json.utf8))
    }

    @Test func notifyCarriesEveryField() throws {
        let request = try decode(
            """
            {"type":"notify","session_id":"dead-beef","title":"Task Complete",
             "subtitle":"auth-refactor — webapp","body":"3 files changed","sound":"Glass"}
            """)
        #expect(
            request
                == .notify(
                    NotifyRequest(
                        sessionID: "dead-beef",
                        title: "Task Complete",
                        subtitle: "auth-refactor — webapp",
                        body: "3 files changed",
                        sound: "Glass"
                    )))
    }

    // A missing subtitle or body is not worth refusing a notification over.
    @Test func notifyToleratesAbsentOptionalStrings() throws {
        let request = try decode(#"{"type":"notify","session_id":"abc","title":"T"}"#)
        guard case .notify(let notify) = request else {
            Issue.record("expected notify, got \(request)")
            return
        }
        #expect(notify.subtitle.isEmpty)
        #expect(notify.body.isEmpty)
        #expect(notify.sound == nil)
    }

    // An explicit empty sound is how a hook asks for a silent notification;
    // it must not become a request for a sound literally named "".
    @Test func emptySoundMeansSilent() throws {
        let request = try decode(#"{"type":"notify","session_id":"abc","title":"T","sound":""}"#)
        guard case .notify(let notify) = request else {
            Issue.record("expected notify, got \(request)")
            return
        }
        #expect(notify.sound == nil)
    }

    @Test func notifyWithoutTitleIsRejected() {
        #expect(throws: RequestDecodeError.missingField("title")) {
            try decode(#"{"type":"notify","session_id":"abc"}"#)
        }
    }

    @Test func notifyWithBadSessionIDIsRejected() {
        #expect(throws: RequestDecodeError.invalidSessionID("../etc")) {
            try decode(#"{"type":"notify","session_id":"../etc","title":"T"}"#)
        }
    }

    @Test func dismissAndAnchorAndPing() throws {
        #expect(try decode(#"{"type":"dismiss","session_id":"abc"}"#) == .dismiss(sessionID: "abc"))
        #expect(
            try decode(#"{"type":"anchor","session_id":"abc"}"#)
                == .anchor(sessionID: "abc", tabID: nil))
        #expect(try decode(#"{"type":"ping"}"#) == .ping)
        #expect(try decode(#"{"type":"style_hint"}"#) == .styleHint)
    }

    // The hook passes the tab id ghostty-tab-save.sh resolved, which beats the
    // agent sampling whatever happens to be focused when it drains.
    @Test func anchorCarriesTheTabIdWhenTheHookKnowsIt() throws {
        #expect(
            try decode(#"{"type":"anchor","session_id":"abc","tab_id":"TAB-1"}"#)
                == .anchor(sessionID: "abc", tabID: "TAB-1"))
        // An empty tab_id means "unknown", not a tab literally named "".
        #expect(
            try decode(#"{"type":"anchor","session_id":"abc","tab_id":""}"#)
                == .anchor(sessionID: "abc", tabID: nil))
    }

    @Test func notifyCarriesTheTabIdTimeoutAndOptOut() throws {
        let request = try decode(
            """
            {"type":"notify","session_id":"abc","title":"T","tab_id":"TAB-7",
             "timeout":1200,"clear_on_focus":false}
            """)
        guard case .notify(let notify) = request else {
            Issue.record("expected notify, got \(request)")
            return
        }
        #expect(notify.tabID == "TAB-7")
        #expect(notify.timeout == 1200)
        #expect(notify.clearOnFocus == false)
    }

    // Both knobs are documented; their defaults must survive an absent field.
    @Test func timeoutAndOptOutDefaults() throws {
        guard
            case .notify(let notify) = try decode(
                #"{"type":"notify","session_id":"abc","title":"T"}"#)
        else {
            Issue.record("expected notify")
            return
        }
        #expect(notify.timeout == nil)
        #expect(notify.clearOnFocus == true)
    }

    // A zero or negative timeout must mean "never expire", not "expire now" —
    // fail towards keeping the alert on screen.
    @Test(arguments: ["0", "-5", "\"\"", "\"nonsense\"", "null"])
    func nonPositiveTimeoutMeansNoTimeout(_ literal: String) throws {
        guard
            case .notify(let notify) = try decode(
                #"{"type":"notify","session_id":"abc","title":"T","timeout":\#(literal)}"#)
        else {
            Issue.record("expected notify")
            return
        }
        #expect(notify.timeout == nil)
    }

    // jq --argjson writes a real boolean, but a hook built by hand may pass the
    // shell's string form. Both have to disable clearing.
    @Test(arguments: ["false", "\"false\"", "\"0\"", "\"off\"", "\"NO\""])
    func stringyFalseAlsoDisablesClearing(_ literal: String) throws {
        guard
            case .notify(let notify) = try decode(
                #"{"type":"notify","session_id":"abc","title":"T","clear_on_focus":\#(literal)}"#)
        else {
            Issue.record("expected notify")
            return
        }
        #expect(notify.clearOnFocus == false)
    }

    @Test func unknownTypeIsRejected() {
        #expect(throws: RequestDecodeError.unknownType("selfDestruct")) {
            try decode(#"{"type":"selfDestruct"}"#)
        }
    }

    @Test func missingTypeIsRejected() {
        #expect(throws: RequestDecodeError.missingType) {
            try decode(#"{"session_id":"abc"}"#)
        }
    }

    // A half-written spool file must be dropped, not guessed at.
    @Test(arguments: ["", "not json at all", "[1,2,3]", #"{"type":"noti"#])
    func malformedInputThrows(_ json: String) {
        #expect(throws: (any Error).self) {
            try decode(json)
        }
    }

    @Test func roundTrip() throws {
        let cases: [AgentRequest] = [
            .notify(
                NotifyRequest(
                    sessionID: "abc", title: "T", subtitle: "S", body: "B", sound: "Glass",
                    tabID: "TAB-1", timeout: 1200, clearOnFocus: false)),
            .notify(NotifyRequest(sessionID: "abc", title: "T")),
            .dismiss(sessionID: "abc"),
            .anchor(sessionID: "abc", tabID: "TAB-1"),
            .anchor(sessionID: "abc", tabID: nil),
            .ping,
            .styleHint,
        ]
        for request in cases {
            #expect(try RequestCodec.decode(RequestCodec.encode(request)) == request)
        }
    }
}
