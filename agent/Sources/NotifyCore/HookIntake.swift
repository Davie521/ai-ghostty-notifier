import Foundation

/// Parses once, in the process that still belongs to the CLI's process tree.
/// No JSON parser subprocess, ambient resident settings or shell expansion.
public enum HookIntake {
    public static func parse(
        data: Data, source: HookSource, expectedEvent: String? = nil,
        environment: [String: String], hooksDirectory: String,
        cwd: String = FileManager.default.currentDirectoryPath,
        now: Double = Date().timeIntervalSince1970,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        inspector: any ProcessInspecting = MacProcessInspector()
    ) throws -> HookEvent? {
        guard
            environment["TERM_PROGRAM"] == "ghostty"
                || !(environment["GHOSTTY_RESOURCES_DIR"] ?? "").isEmpty, !data.isEmpty
        else { return nil }
        guard let home = environment["HOME"], home.hasPrefix("/"), home != "/",
            !home.contains("\0"), now.isFinite, now > 0, now < Double(Int.max)
        else { throw AgentPathsError.missingHome }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RequestDecodeError.missingField("hook JSON object")
        }
        if let raw = object["hook_event_name"], !(raw is String), !(raw is NSNull) {
            throw RequestDecodeError.missingField("string hook_event_name")
        }
        let supplied = object["hook_event_name"] as? String ?? ""
        if let expectedEvent, !supplied.isEmpty, supplied != expectedEvent { return nil }
        let name = expectedEvent ?? supplied
        guard let kind = HookKind(rawValue: name),
            source != .codex || kind == .prompt || kind == .stop
        else { return nil }
        object["hook_event_name"] = name
        var payload = try JSONDecoder().decode(
            HookPayload.self,
            from: JSONSerialization.data(withJSONObject: object))
        guard RequestCodec.isValidSessionID(payload.sessionID), payload.agentID?.isEmpty != false
        else { return nil }
        if payload.cwd?.isEmpty != false { payload.cwd = cwd }
        if let prompt = payload.prompt {
            payload.prompt = String(String.UnicodeScalarView(prompt.unicodeScalars.prefix(200)))
        }

        var env = environment
        if source == .codex,
            let config = FileManager.default.contents(atPath: hooksDirectory + "/config.json")
        {
            env = try merging(config: config, environment: environment)
        }
        for key in [
            "CODEX_HOME", "CODEX_SQLITE_HOME", "GHOSTTY_NOTIFY_SESSION_DIR",
            "GHOSTTY_NOTIFY_RATE_DIR", "GHOSTTY_NOTIFY_TTY",
        ] {
            if env[key]?.contains("\0") == true { throw CocoaError(.fileWriteInvalidFileName) }
        }
        let codexHome = absolute(
            env["CODEX_HOME"], fallback: home + "/.codex", home: home, cwd: cwd)
        let notifications = (source == .codex ? codexHome : home + "/.claude") + "/notifications"
        let sessions = absolute(
            env["GHOSTTY_NOTIFY_SESSION_DIR"],
            fallback: notifications + "/ghostty-sessions", home: home, cwd: cwd)
        let rates = absolute(
            env["GHOSTTY_NOTIFY_RATE_DIR"],
            fallback: notifications + "/state", home: home, cwd: cwd)
        var settings = env.filter {
            $0.key.hasPrefix("GHOSTTY_NOTIFY_") && !$0.value.contains("\0")
        }
        for key in ["GHOSTTY_NOTIFY_AGENT_APP"] {
            if let value = settings[key], !value.isEmpty {
                settings[key] = absolute(value, fallback: value, home: home, cwd: cwd)
            }
        }
        settings["GHOSTTY_NOTIFY_PROCESS_NAME"] = source.rawValue
        if source == .codex {
            settings["GHOSTTY_NOTIFY_APP_NAME"] = "Codex"
            if (settings["GHOSTTY_NOTIFY_GROUP_PREFIX"] ?? "").isEmpty {
                settings["GHOSTTY_NOTIFY_GROUP_PREFIX"] = "codex-ghostty-notify"
            }
        }
        var event = HookEvent(
            source: source, roundID: UUID().uuidString, occurredAt: now,
            sessionDirectory: sessions, rateDirectory: rates, hooksDirectory: hooksDirectory,
            settings: settings, payload: payload)
        event.homeDirectory = home
        event.searchPath = env["PATH"]
        event.codexHome = codexHome
        event.codexSQLiteHome = env["CODEX_SQLITE_HOME"].map {
            absolute($0, fallback: codexHome, home: home, cwd: cwd)
        }
        let owner = HookProcessContext.owner(
            source: source, startingAt: processID, inspector: inspector)
        // Desktop and MCP sessions have no terminal owner, even if they happen
        // to inherit TERM_PROGRAM or someone configures a TTY override.
        if source == .codex, owner == nil { return nil }
        event.owner = owner?.owner
        event.tty =
            env["GHOSTTY_NOTIFY_TTY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? owner?.tty ?? inspector.process(processID)?.tty
        // A session with no terminal anywhere is not sitting in a tab, whatever
        // the environment says: TERM_PROGRAM and GHOSTTY_RESOURCES_DIR are
        // inherited, so a headless `claude -p` started by a server or a script
        // that was itself launched from Ghostty passes the check above. Taken
        // for a tab's session, every run posted a banner — each gets a fresh
        // session id, so the rate limit never saw the same key twice — and was
        // anchored to whichever tab happened to be focused (issue #9). An
        // interactive session always has one, under tmux too: its CLI's, or
        // this hook's own controlling terminal when the CLI runs under a name
        // the walk does not know; GHOSTTY_NOTIFY_TTY names one outright.
        if event.tty == nil { return nil }
        return try HookEvent.decode(JSONEncoder().encode(event))
    }

    public static func merging(config: Data, environment: [String: String]) throws -> [String:
        String]
    {
        guard let object = try JSONSerialization.jsonObject(with: config) as? [String: Any] else {
            throw RequestDecodeError.missingField("config JSON object")
        }
        var result = environment
        for (key, value) in object
        where result[key] == nil
            && key.range(of: #"^GHOSTTY_NOTIFY_[A-Z0-9_]+$"#, options: .regularExpression) != nil
            && !(value is NSNull)
        {
            let text: String
            if let string = value as? String {
                text = string
            } else {
                text = String(
                    decoding: try JSONSerialization.data(
                        withJSONObject: value,
                        options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
            }
            if !text.contains("\0") { result[key] = text }
        }
        return result
    }

    private static func absolute(_ value: String?, fallback: String, home: String, cwd: String)
        -> String
    {
        var path = value?.isEmpty == false ? value! : fallback
        if path.hasPrefix("~/") { path = home + String(path.dropFirst()) }
        if !path.hasPrefix("/") { path = cwd + "/" + path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
