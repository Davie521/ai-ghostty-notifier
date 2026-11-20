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
    /// The prompt that started the Claude turn. A message sent while a turn
    /// runs joins it under the same id; a turn that is interrupted never
    /// reaches a Stop with its id.
    public var promptID: String?
    /// Who wrote a Claude prompt: `user` typed it, `sdk` is headless; `system`,
    /// `loop_wakeup`, `schedule_wakeup` and `poll_event` were injected.
    public var promptSource: String?
    /// The background work still running when a Claude turn stopped. Claude
    /// wakes the session again when any of it ends.
    public var backgroundTasks: [BackgroundTask]?
    /// The list had an entry that may wake the session but could not be
    /// identified, so it does not tell what runs.
    public var backgroundUnidentified: Bool?

    public init(sessionID: String, kind: HookKind, cwd: String? = nil) {
        self.sessionID = sessionID
        self.hookEventName = kind.rawValue
        self.cwd = cwd
    }

    /// The new fields are read leniently: they are still rolling out, and a
    /// shape this version does not expect must not cost the whole event.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        hookEventName = try container.decode(String.self, forKey: .hookEventName)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        sessionTitle = try container.decodeIfPresent(String.self, forKey: .sessionTitle)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        promptID = (try? container.decodeIfPresent(String.self, forKey: .promptID))
            .flatMap { $0 }.flatMap(BackgroundTask.usable)
        promptSource = (try? container.decodeIfPresent(String.self, forKey: .promptSource))
            .flatMap { $0 }.map { String($0.prefix(40)) }
        let entries =
            (try? container.decodeIfPresent(
                [BackgroundTask.Lenient].self, forKey: .backgroundTasks)).flatMap { $0 }
        backgroundTasks = entries.map { $0.compactMap(\.task) }
        let unidentified =
            entries?.contains(where: \.unidentified) == true
            || (try? container.decodeIfPresent(Bool.self, forKey: .backgroundUnidentified)) == true
        backgroundUnidentified = unidentified ? true : nil
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
        case promptID = "prompt_id"
        case promptSource = "source"
        case backgroundTasks = "background_tasks"
        case backgroundUnidentified = "ghostty_notify_background_unidentified"
    }
}

/// One entry of Claude's `background_tasks`. Only what tells entries apart is
/// kept; descriptions and command lines stay in the CLI. The hook reads the
/// whole list and drops it once it has decided (`RoundJournal.capture`).
public struct BackgroundTask: Codable, Equatable, Sendable {
    /// The kinds that report back by waking the session. The list also
    /// carries Claude's own housekeeping ("dream", "auto-mode scan", …); a
    /// kind not known to wake it must not hold a completion that may never
    /// come, so anything else is ignored, as before this was read at all.
    public static let wakingTypes: Set<String> = ["shell", "subagent", "monitor", "workflow"]
    public var id: String
    public var type: String?

    public init(id: String, type: String? = nil) {
        self.id = id
        self.type = type
    }

    public var wakesSession: Bool { type.map(Self.wakingTypes.contains) ?? false }

    /// Whether it may be work that wakes the session: a known waking kind, or
    /// one whose kind was not given. A baseline keeps these, so a task seen
    /// once untyped is not taken for new work when its kind shows up.
    public var mayWakeSession: Bool { type.map(Self.wakingTypes.contains) ?? true }

    /// An identifier fit for a one-per-line state file.
    static func usable(_ id: String) -> String? {
        !id.isEmpty && id.count <= 200 && id != "*"
            && !id.contains(where: { $0.isNewline || $0 == "\t" }) ? id : nil
    }

    /// Never throws: an entry without a usable id is dropped, not fatal, and
    /// marked when it may be one that wakes the session.
    struct Lenient: Decodable {
        var task: BackgroundTask?
        var unidentified = false
        init(from decoder: Decoder) {
            let container = try? decoder.container(keyedBy: BackgroundTask.CodingKeys.self)
            let type = (try? container?.decodeIfPresent(String.self, forKey: .type)).flatMap { $0 }
            guard let id = (try? container?.decode(String.self, forKey: .id)).flatMap(usable)
            else {
                unidentified = type.map(BackgroundTask.wakingTypes.contains) ?? true
                return
            }
            task = BackgroundTask(
                id: id, type: type.map { String(NotificationPolicy.clean($0).prefix(40)) })
        }
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
    /// Set by the hook on a Claude Stop that leaves background work of this
    /// round running: Claude will wake the session again, so the round is
    /// paused, not finished. Absent from events of older hooks.
    public var awaitingBackground: Bool?
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
    /// A Claude prompt nobody typed: a background task reporting back, a
    /// scheduled wakeup. It resumes the work in progress rather than starting
    /// new work. Without a known `source` (2.1.329 does not send it), a
    /// finished task's report is recognizable by its text.
    public var isInjectedPrompt: Bool {
        guard source == .claude, kind == .prompt else { return false }
        switch payload.promptSource {
        case "system", "loop_wakeup", "schedule_wakeup", "poll_event": return true
        case "user", "sdk": return false
        default: return Self.isTaskReport(payload.prompt ?? "")
        }
    }

    /// An injected prompt that is a background task reporting back, the one
    /// kind that resumes a round paused on it. A scheduled job is not one.
    public var isTaskReport: Bool {
        isInjectedPrompt && Self.isTaskReport(payload.prompt ?? "")
    }

    /// The report's own structure, not just its first word: a person may well
    /// begin a message with the tag.
    static func isTaskReport(_ prompt: String) -> Bool {
        let text = prompt.drop(while: \.isWhitespace)
        guard text.hasPrefix("<task-notification>") else { return false }
        let report = text.dropFirst("<task-notification>".count).drop(while: \.isWhitespace)
        return report.hasPrefix("<task-id>") && report.contains("</task-id>")
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
        case awaitingBackground = "awaiting_background"
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
    public var nudgeSound: Bool
    public var waitBackground: Bool
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
        nudgeSound = ["1", "true", "yes", "on"].contains(
            (settings["GHOSTTY_NOTIFY_NUDGE_SOUND"] ?? "0").lowercased())
        waitBackground = !["0", "false", "no", "off"].contains(
            (settings["GHOSTTY_NOTIFY_WAIT_BACKGROUND"] ?? "1").lowercased())
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
            (title.isEmpty
                ? UIText.text(completed ? "Task Complete" : "Input Required") : title)
            + " — " + event.project
        let body =
            completed
            ? UIText.format(
                "Finished after %.0fm %.0fs", floor(elapsed / 60),
                floor(elapsed.truncatingRemainder(dividingBy: 60)))
            : (event.payload.message ?? UIText.text("Claude is waiting for you"))
        return NotifyRequest(
            sessionID: event.sessionID, title: app,
            subtitle: clean(subtitle), body: clean(body),
            sound: completed ? (elapsed >= options.soundAfter ? "Glass" : nil) : "Ping",
            tabID: tabID, timeout: options.timeout, clearOnFocus: options.clearOnFocus,
            roundID: event.roundID, source: event.source, owner: event.owner)
    }

    public static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })
    }
}
