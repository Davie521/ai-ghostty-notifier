import CSQLite
import Foundation

public protocol SessionContentProviding: Sendable {
    func title(for event: HookEvent) async -> String
    func isContinuing(_ event: HookEvent) async -> Bool
}

/// Disk reads run on the actor's executor. JSONL is streamed in bounded chunks;
/// only title records are decoded, and the transcript itself is never retained.
public actor DiskSessionContent: SessionContentProviding {
    public init() {}

    public func title(for event: HookEvent) async -> String {
        if let title = event.payload.sessionTitle, !title.isEmpty {
            return NotificationPolicy.clean(title)
        }
        if event.source == .codex {
            let stored = await codexTitle(event)
            if !stored.isEmpty { return NotificationPolicy.clean(stored) }
            return NotificationPolicy.clean(
                DiskRoundJournal.read(
                    event.sessionDirectory + "/" + event.sessionID + ".title"))
        }
        guard let path = event.payload.transcriptPath,
            let file = FileHandle(forReadingAtPath: path)
        else { return "" }
        defer { try? file.close() }
        var buffer = Data()
        var custom = ""
        var ai = ""
        var discardingLongLine = false
        while !Task.isCancelled {
            guard let chunk = try? file.read(upToCount: 65_536), !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                if !discardingLongLine, let text = String(data: line, encoding: .utf8),
                    text.contains("custom-title") || text.contains("ai-title"),
                    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                {
                    if object["type"] as? String == "custom-title",
                        let value = object["customTitle"] as? String
                    {
                        custom = value
                    }
                    if object["type"] as? String == "ai-title",
                        let value = object["aiTitle"] as? String
                    {
                        ai = value
                    }
                }
                buffer.removeSubrange(...newline)
                discardingLongLine = false
            }
            if buffer.count > 1_048_576 {
                buffer.removeAll(keepingCapacity: true)
                discardingLongLine = true
            }
        }
        // The last line need not end in a newline (the CLI can still be writing).
        if !discardingLongLine,
            let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any]
        {
            if object["type"] as? String == "custom-title",
                let value = object["customTitle"] as? String
            {
                custom = value
            }
            if object["type"] as? String == "ai-title", let value = object["aiTitle"] as? String {
                ai = value
            }
        }
        return NotificationPolicy.clean(
            (custom.isEmpty ? ai : custom)
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        )
    }

    public func isContinuing(_ event: HookEvent) -> Bool {
        guard event.source == .codex, let turn = event.payload.turnID, !turn.isEmpty,
            let path = event.payload.transcriptPath, let file = FileHandle(forReadingAtPath: path)
        else { return false }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return false }
        let offset = size > 262_144 ? size - 262_144 : 0
        try? file.seek(toOffset: offset)
        guard let data = try? file.readToEnd() else { return false }
        // A bounded tail can start in the middle of a UTF-8 character. The
        // incomplete first record must not hide valid records after it.
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("task_started") {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                object["type"] as? String == "event_msg",
                let payload = object["payload"] as? [String: Any],
                payload["type"] as? String == "task_started"
            else { continue }
            guard let latest = payload["turn_id"] as? String, !latest.isEmpty, latest != turn else {
                return false
            }
            let started =
                (payload["started_at"] as? NSNumber)?.doubleValue
                ?? (payload["started_at"] as? String).flatMap(Double.init)
            return started.map { floor($0) + 5 >= event.occurredAt } ?? true
        }
        return false
    }

    private func codexTitle(_ event: HookEvent) async -> String {
        guard let home = event.codexHome, !home.isEmpty else { return "" }
        var directory = event.codexSQLiteHome.flatMap { $0.isEmpty ? nil : $0 } ?? home
        let config = DiskRoundJournal.read(home + "/config.toml")
        // This mirrors the CLI adapter's supported top-level quoted setting.
        // Stop at the first table so a similarly named nested key cannot win.
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            if let range = trimmed.range(
                of: #"^sqlite_home\s*=\s*\"([^\"]*)\""#, options: .regularExpression)
            {
                let assignment = String(trimmed[range])
                let configured = assignment.components(separatedBy: "\"")[1]
                if !configured.isEmpty { directory = configured }
                break
            }
        }
        if directory.hasPrefix("~/") {
            directory =
                FileManager.default.homeDirectoryForCurrentUser.path + "/" + directory.dropFirst(2)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return ""
        }
        let candidates = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                let version = Int(name.dropFirst(6).dropLast(7))
            else { return nil }
            return (version, name)
        }
        guard let best = candidates.max(by: { $0.0 < $1.0 }) else { return "" }
        return SQLiteThreadNames.read(
            database: directory + "/" + best.1, sessionID: event.sessionID)
    }
}

/// System SQLite, not the sqlite3 command. The database is never created or
/// written and a bound parameter keeps session identity out of SQL source.
public enum SQLiteThreadNames {
    public static func read(database: String, sessionID: String) -> String {
        var connection: OpaquePointer?
        guard
            sqlite3_open_v2(database, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK, let connection
        else {
            if let connection { sqlite3_close(connection) }
            return ""
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 200)
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                connection, "SELECT name FROM threads WHERE id = ? LIMIT 1", -1,
                &statement, nil) == SQLITE_OK, let statement
        else { return "" }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW,
            let text = sqlite3_column_text(statement, 0)
        else { return "" }
        return String(cString: text).components(separatedBy: .newlines).first ?? ""
    }
}
