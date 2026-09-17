import Foundation

/// Requests the hooks drop into the spool directory, one JSON object per file.
///
/// The wire format is deliberately dumb: a flat JSON object with a `type`
/// discriminator; old clients can still write the v1 form by atomic rename.
/// Decoding is fail-closed — an unparseable or half-written file is dropped
/// rather than guessed at, because the writer's `mv` is what makes a request
/// visible and a partial file therefore means a bug, not a race.
public enum AgentRequest: Equatable, Sendable {
    case hookEvent(HookEvent)
    /// Post a notification for a session.
    case notify(NotifyRequest)
    /// Withdraw every notification belonging to a session. Sent by the
    /// UserPromptSubmit hook: submitting a prompt proves the user is back.
    case dismiss(sessionID: String, source: HookSource = .claude)
    /// Record which Ghostty tab a session lives in.
    ///
    /// `tabID` comes from the hook, which reads the id that
    /// `ghostty-tab-save.sh` resolved with an OSC-2 marker round-trip. That id
    /// is correct no matter what is focused later, which is why it is preferred
    /// over the agent sampling the frontmost surface at drain time — the drain
    /// can happen a second or more after the prompt was submitted, by which
    /// point the user may be looking at a different tab entirely.
    case anchor(sessionID: String, tabID: String?, source: HookSource = .claude)
    /// Liveness probe used by the install script and the integration test.
    case ping
    /// Show the alert-style guidance dialog even if it has been shown before.
    /// Sent by the install script when macOS has this app on Temporary style,
    /// which is the one thing the product needs that no code can set.
    case styleHint
}

public struct NotifyRequest: Equatable, Sendable {
    public var roundID: String?
    public var owner: String?
    public var source: HookSource
    public var stateKey: String { source == .claude ? sessionID : "codex-" + sessionID }
    public var sessionID: String
    public var title: String
    public var subtitle: String
    public var body: String
    /// Notification sound name; `nil` posts silently.
    public var sound: String?
    /// Tab id if the hook already knows it, so the very first notification of a
    /// session is localizable without waiting for an anchor.
    public var tabID: String?
    /// Withdraw the notification unconditionally after this many seconds.
    /// Mirrors the shell path's `--timeout`. `nil` means it stays until focus,
    /// a prompt, or a click removes it.
    public var timeout: Double?
    /// False when the user set GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0. Such a
    /// notification is never withdrawn by a focus change — some people keep
    /// them in Notification Center as a to-do list.
    public var clearOnFocus: Bool

    public init(
        sessionID: String,
        title: String,
        subtitle: String = "",
        body: String = "",
        sound: String? = nil,
        tabID: String? = nil,
        timeout: Double? = nil,
        clearOnFocus: Bool = true,
        roundID: String? = nil,
        source: HookSource = .claude,
        owner: String? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sound = sound
        self.tabID = tabID
        self.timeout = timeout
        self.clearOnFocus = clearOnFocus
        self.roundID = roundID
        self.source = source
        self.owner = owner
    }
}

public enum RequestDecodeError: Error, Equatable {
    case notAnObject
    case missingType
    case unknownType(String)
    case missingField(String)
    case invalidSessionID(String)
}

public enum RequestCodec {
    /// Session ids reach us from hook stdin and are used as dictionary keys and
    /// (via the notification identifier) handed to the notification center.
    /// Constrain them to the UUID-ish shape Claude Code emits so nothing
    /// downstream has to defend against separators.
    public static func isValidSessionID(_ id: String) -> Bool {
        // Match the hook's ASCII UUID alphabet, not Unicode Hex_Digit (which
        // includes fullwidth lookalikes). The same predicate scopes pruning.
        !id.isEmpty
            && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                    || $0 == 45
            }
    }

    public static func decode(_ data: Data) throws -> AgentRequest {
        let raw = try? JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw RequestDecodeError.notAnObject
        }
        guard let type = object["type"] as? String, !type.isEmpty else {
            throw RequestDecodeError.missingType
        }

        func session() throws -> String {
            guard let id = object["session_id"] as? String else {
                throw RequestDecodeError.missingField("session_id")
            }
            guard isValidSessionID(id) else {
                throw RequestDecodeError.invalidSessionID(id)
            }
            return id
        }

        // Absent string fields degrade to empty rather than failing: a
        // notification with no subtitle is still worth showing.
        func string(_ key: String) -> String {
            (object[key] as? String) ?? ""
        }
        /// Absent or blank optional strings are "not supplied", never "".
        func optional(_ key: String) -> String? {
            let value = string(key)
            return value.isEmpty ? nil : value
        }
        func source() throws -> HookSource {
            guard let raw = object["source"] else { return .claude }
            guard let text = raw as? String, let value = HookSource(rawValue: text) else {
                throw RequestDecodeError.missingField("valid source")
            }
            return value
        }

        switch type {
        case "hook_event":
            return .hookEvent(try HookEvent.decode(data))
        case "notify":
            let title = string("title")
            guard !title.isEmpty else {
                throw RequestDecodeError.missingField("title")
            }
            // A non-positive or unparseable timeout means "no timeout" rather
            // than "expire immediately" — fail towards keeping the alert.
            var timeout: Double?
            if let number = object["timeout"] as? NSNumber, number.doubleValue > 0 {
                timeout = number.doubleValue
            } else if let text = object["timeout"] as? String, let value = Double(text),
                value > 0
            {
                timeout = value
            }
            // Any explicit false disables clearing; anything else keeps the
            // documented default on, matching how the shell hook reads the
            // same switch.
            var clearOnFocus = true
            if let flag = object["clear_on_focus"] as? Bool {
                clearOnFocus = flag
            } else if let flag = object["clear_on_focus"] as? NSNumber {
                clearOnFocus = flag.boolValue
            } else if let text = object["clear_on_focus"] as? String {
                clearOnFocus = !["0", "false", "no", "off"].contains(text.lowercased())
            }

            return .notify(
                NotifyRequest(
                    sessionID: try session(),
                    title: title,
                    subtitle: string("subtitle"),
                    body: string("body"),
                    sound: optional("sound"),
                    tabID: optional("tab_id"),
                    timeout: timeout,
                    clearOnFocus: clearOnFocus,
                    roundID: optional("round_id"),
                    source: try source(),
                    owner: optional("owner")
                )
            )
        case "dismiss":
            return .dismiss(sessionID: try session(), source: try source())
        case "anchor":
            return .anchor(
                sessionID: try session(), tabID: optional("tab_id"), source: try source())
        case "ping":
            return .ping
        case "style_hint":
            return .styleHint
        default:
            throw RequestDecodeError.unknownType(type)
        }
    }

    /// Round-trip counterpart, used by tests and by `--send` in the agent
    /// binary. Native hook and worker modes share this codec.
    public static func encode(_ request: AgentRequest) throws -> Data {
        var object: [String: Any]
        switch request {
        case .hookEvent(let event):
            let data = try JSONEncoder().encode(event)
            object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object["type"] = "hook_event"
        case .notify(let n):
            object = [
                "type": "notify",
                "session_id": n.sessionID,
                "title": n.title,
                "subtitle": n.subtitle,
                "body": n.body,
                "clear_on_focus": n.clearOnFocus,
            ]
            if let sound = n.sound { object["sound"] = sound }
            if let tabID = n.tabID { object["tab_id"] = tabID }
            if let timeout = n.timeout { object["timeout"] = timeout }
            if let round = n.roundID { object["round_id"] = round }
            if let owner = n.owner { object["owner"] = owner }
            if n.source != .claude { object["source"] = n.source.rawValue }
        case .dismiss(let sessionID, let source):
            object = ["type": "dismiss", "session_id": sessionID]
            if source != .claude { object["source"] = source.rawValue }
        case .anchor(let sessionID, let tabID, let source):
            object = ["type": "anchor", "session_id": sessionID]
            if let tabID { object["tab_id"] = tabID }
            if source != .claude { object["source"] = source.rawValue }
        case .ping:
            object = ["type": "ping"]
        case .styleHint:
            object = ["type": "style_hint"]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
