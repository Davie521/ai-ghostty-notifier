import Foundation

public enum HookSource: String, Codable, Sendable { case claude, codex }
public enum HookKind: String, Codable, Sendable {
    case prompt = "UserPromptSubmit"
    case stop = "Stop"
    case notification = "Notification"
    case preTool = "PreToolUse"
}

/// Facts captured by the hook, not a preformatted notification. Optional payload
/// fields deliberately stay optional: neither CLI promises them on every event.
public struct HookPayload: Codable, Equatable, Sendable {
    public var sessionID: String
    public var cwd: String?
    public var hookEventName: String
    public var transcriptPath: String?
    public var sessionTitle: String?
    public var message: String?
    public var prompt: String?
    public var turnID: String?
    public var agentID: String?

    public init(sessionID: String, kind: HookKind, cwd: String? = nil) {
        self.sessionID = sessionID
        self.hookEventName = kind.rawValue
        self.cwd = cwd
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case transcriptPath = "transcript_path"
        case sessionTitle = "session_title"
        case message, prompt
        case turnID = "turn_id"
        case agentID = "agent_id"
    }
}

public struct HookEvent: Codable, Equatable, Sendable {
    public static let version = 1
    public var version: Int = Self.version
    public var source: HookSource
    public var roundID: String
    public var occurredAt: Double
    public var startedAt: Double
    public var sessionDirectory: String
    public var rateDirectory: String
    public var hooksDirectory: String
    public var settings: [String: String]
    public var owner: String?
    public var tty: String?
    public var codexHome: String?
    public var codexSQLiteHome: String?
    public var homeDirectory: String?
    public var searchPath: String?
    public var payload: HookPayload

    public init(
        source: HookSource = .claude, roundID: String, occurredAt: Double,
        startedAt: Double = 0, sessionDirectory: String, rateDirectory: String,
        hooksDirectory: String = "", settings: [String: String] = [:],
        payload: HookPayload
    ) {
        self.source = source
        self.roundID = roundID
        self.occurredAt = occurredAt
        self.startedAt = startedAt
        self.sessionDirectory = sessionDirectory
        self.rateDirectory = rateDirectory
        self.hooksDirectory = hooksDirectory
        self.settings = settings
        self.payload = payload
    }

    public var kind: HookKind { HookKind(rawValue: payload.hookEventName)! }
    public var sessionID: String { payload.sessionID }
    public var key: String { source == .claude ? sessionID : "codex-" + sessionID }
    public var options: HookOptions { HookOptions(settings) }
    public var expiresAt: Double { occurredAt + AgentConstants.staleNotifyAge }
    public var project: String {
        URL(fileURLWithPath: payload.cwd ?? "").lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case version, source
        case roundID = "round_id"
        case occurredAt = "occurred_at"
        case startedAt = "started_at"
        case sessionDirectory = "session_dir"
        case rateDirectory = "rate_dir"
        case hooksDirectory = "hooks_dir"
        case settings
        case owner, tty
        case codexHome = "codex_home"
        case codexSQLiteHome = "codex_sqlite_home"
        case homeDirectory = "home_dir"
        case searchPath = "search_path"
        case payload
    }

    public static func decode(_ data: Data) throws -> HookEvent {
        let event = try JSONDecoder().decode(HookEvent.self, from: data)
        guard event.version == Self.version else {
            throw RequestDecodeError.unknownType("hook_event v\(event.version)")
        }
        guard RequestCodec.isValidSessionID(event.sessionID) else {
            throw RequestDecodeError.invalidSessionID(event.sessionID)
        }
        guard HookKind(rawValue: event.payload.hookEventName) != nil,
            event.payload.agentID?.isEmpty != false,
            !event.roundID.isEmpty, event.roundID.count <= 160,
            event.roundID.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45
            }),
            event.occurredAt.isFinite, event.occurredAt > 0, event.occurredAt < Double(Int.max),
            event.startedAt.isFinite, event.startedAt >= 0,
            [event.sessionDirectory, event.rateDirectory].allSatisfy({
                $0.hasPrefix("/") && $0 != "/" && !$0.contains("\0")
            })
        else { throw RequestDecodeError.missingField("valid hook context") }
        return event
    }
}

public struct HookOptions: Equatable, Sendable {
    public var minimum: Double
    public var soundAfter: Double
    public var timeout: Double?
    public var onPrompt: Bool
    public var clearOnFocus: Bool
    public var settle: Double
    public var backend: String
    public var prefersResident: Bool { ["auto", "agent"].contains(backend) }

    public init(_ settings: [String: String]) {
        func integer(_ name: String, _ fallback: Double) -> Double {
            guard let text = settings["GHOSTTY_NOTIFY_" + name], !text.isEmpty,
                text.utf8.allSatisfy({ (48...57).contains($0) }),
                let value = Double(text), value.isFinite
            else { return fallback }
            return value
        }
        minimum = integer("MIN_ELAPSED", 180)
        soundAfter = integer("SOUND_ELAPSED", 600)
        let seconds = integer("TIMEOUT", 1200)
        timeout = seconds > 0 ? seconds : nil
        // Unlike AGENT_APP and MARKER_RETRY_DELAYS, an empty BACKEND has
        // always meant the default (`${BACKEND:-auto}` in the shell hooks).
        backend = settings["GHOSTTY_NOTIFY_BACKEND"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        onPrompt = settings["GHOSTTY_NOTIFY_ON_PROMPT"] == "1"
        clearOnFocus = !["0", "false", "no", "off"].contains(
            (settings["GHOSTTY_NOTIFY_CLEAR_ON_FOCUS"] ?? "1").lowercased())
        if let text = settings["GHOSTTY_NOTIFY_CODEX_SETTLE"],
            text.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
            let value = Double(text), value.isFinite
        {
            settle = value
        } else {
            settle = 1.5
        }
    }
}

public enum NotificationPolicy {
    public static func qualifies(_ event: HookEvent) -> Bool {
        switch event.kind {
        case .prompt, .preTool: return false
        case .notification: return event.options.onPrompt
        case .stop:
            return event.startedAt > 0 && event.occurredAt >= event.startedAt
                && event.occurredAt - event.startedAt >= event.options.minimum
        }
    }

    public static func content(_ event: HookEvent, title: String, tabID: String?) -> NotifyRequest {
        let options = event.options
        let elapsed = max(0, event.occurredAt - event.startedAt)
        let completed = event.kind == .stop
        let app =
            event.source == .codex
            ? "Codex"
            : (event.settings["GHOSTTY_NOTIFY_APP_NAME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? "Claude")
        let subtitle =
            (title.isEmpty ? (completed ? "Task Complete" : "Input Required") : title)
            + " — " + event.project
        let body =
            completed
            ? String(
                format: "Finished after %.0fm %.0fs", floor(elapsed / 60),
                floor(elapsed.truncatingRemainder(dividingBy: 60)))
            : (event.payload.message ?? "Claude is waiting for you")
        return NotifyRequest(
            sessionID: event.sessionID, title: app + (completed ? " ✅" : " 🔔"),
            subtitle: clean(subtitle), body: clean(body),
            sound: completed ? (elapsed >= options.soundAfter ? "Glass" : nil) : "Ping",
            tabID: tabID, timeout: options.timeout, clearOnFocus: options.clearOnFocus,
            roundID: event.roundID, source: event.source, owner: event.owner)
    }

    public static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })
    }
}
