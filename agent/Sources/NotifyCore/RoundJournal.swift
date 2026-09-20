import Darwin
import Foundation

public protocol RoundJournalProviding: Sendable {
    func isCurrent(_ event: HookEvent) async -> Bool
    func prepare(_ event: HookEvent) async
    func finish(_ event: HookEvent) async
    func claimRate(_ event: HookEvent, now: Double) async -> Bool
}

/// Same directory locks and plain-text records as hook-common.sh. Keeping one
/// journal lets cold starts, downgrades and permission failures switch backends
/// without losing the start time or opening a second rate-limit bucket.
public actor DiskRoundJournal: RoundJournalProviding {
    public init() {}

    /// Runs in the short-lived native hook before it returns. A queued prompt
    /// must invalidate old work immediately, not when the resident app drains it.
    public func capture(_ input: HookEvent) throws -> HookEvent {
        guard RequestCodec.isValidSessionID(input.sessionID),
            input.sessionDirectory.hasPrefix("/"), input.sessionDirectory != "/"
        else { throw CocoaError(.fileWriteInvalidFileName) }
        try PrivateFile.createDirectory(input.sessionDirectory)
        guard let lease = DirectoryLease.acquire(path(input, "round-lock")) else {
            throw CocoaError(.fileLocking)
        }
        defer { lease.release() }
        var event = input
        let old = Self.read(path(event, "round"))
        let valid =
            !old.isEmpty && old.count <= 160
            && old.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45
            }
        event.roundID = event.kind == .prompt || !valid ? UUID().uuidString : old
        if event.roundID != old, !write(event.roundID, path(event, "round")) {
            throw CocoaError(.fileWriteUnknown)
        }
        if event.kind == .prompt {
            remove(path(event, "start"))
            if event.source == .codex, !write(String(Int(event.occurredAt)), path(event, "start")) {
                throw CocoaError(.fileWriteUnknown)
            }
        } else if event.kind == .preTool, event.source == .claude,
            !FileManager.default.fileExists(atPath: path(event, "start"))
        {
            guard write(String(Int(event.occurredAt)), path(event, "start")) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let start = Self.read(path(event, "start"))
        if !start.isEmpty, start.utf8.allSatisfy({ (48...57).contains($0) }),
            let value = Double(start), value.isFinite
        {
            event.startedAt = value
        } else {
            event.startedAt = 0
        }
        return event
    }

    public func isCurrent(_ event: HookEvent) -> Bool {
        Self.read(path(event, "round")) == event.roundID
    }

    public func prepare(_ event: HookEvent) {
        _ = withLock(path(event, "round-lock")) {
            guard Self.read(path(event, "round")) == event.roundID else { return false }
            if let owner = event.owner, !owner.isEmpty {
                let ownerSuffix = event.source.rawValue + "-owner"
                let previous = Self.read(path(event, ownerSuffix))
                if previous != owner {
                    remove(path(event, "json"))
                    remove(path(event, "attempts"))
                }
                write(owner, path(event, ownerSuffix))
            }
            if event.source == .codex {
                if event.kind == .prompt, Self.read(path(event, "title")).isEmpty {
                    let first = String((event.payload.prompt ?? "").prefix(200))
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    let title = NotificationPolicy.clean(String(first.prefix(120)))
                    if !title.isEmpty { write(title, path(event, "title")) }
                }
            }
            return true
        }
        prune(event, now: event.occurredAt)
    }

    public func finish(_ event: HookEvent) {
        guard event.kind == .stop else { return }
        _ = withLock(path(event, "round-lock")) {
            guard Self.read(path(event, "round")) == event.roundID else { return false }
            remove(path(event, "start"))
            return true
        }
    }

    public func claimRate(_ event: HookEvent, now: Double) -> Bool {
        let file = Self.rateFile(event)
        try? PrivateFile.createDirectory(event.rateDirectory)
        let result = withLock(file + ".lock") {
            if FileManager.default.fileExists(atPath: file) {
                let value = Self.read(file)
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                    let last = Double(value), last.isFinite
                else {
                    // Match the old shell's corrupt-record behavior: suppress
                    // this attempt and remove the corruption for the next one.
                    remove(file)
                    return false
                }
                if now - last < 10 { return false }
            }
            return write(String(format: "%.0f", floor(now)), file)
        }
        prune(event, now: now)
        return result
    }

    public static func rateFile(_ event: HookEvent) -> String {
        let raw = event.payload.hookEventName + "-" + event.sessionID + "-" + event.project
        // One underscore per Unicode scalar, matching jq's gsub in the
        // compatibility hook regardless of that process's locale.
        let key = raw.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            return (48...57).contains(value) || (65...90).contains(value)
                || (97...122).contains(value) || value == 46 || value == 95 || value == 45
                ? String(scalar) : "_"
        }.joined()
        return event.rateDirectory + "/ghostty-notify-" + key
    }

    private func path(_ event: HookEvent, _ suffix: String) -> String {
        event.sessionDirectory + "/" + event.sessionID + "." + suffix
    }

    public static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .newlines) ?? ""
    }

    @discardableResult private func write(_ value: String, _ path: String) -> Bool {
        do {
            try PrivateFile.write(value + "\n", to: path)
            return true
        } catch { return false }
    }

    private func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    private func withLock(_ directory: String, _ body: () -> Bool) -> Bool {
        guard let lease = DirectoryLease.acquire(directory) else { return false }
        defer { lease.release() }
        return body()
    }

    /// At most hourly per directory. A hook is a new process for every tool
    /// call, so the hour is kept in the directory, where the next one finds it:
    /// kept in memory, every hook listed and examined every session file.
    private func prune(_ event: HookEvent, now: Double) {
        let fm = FileManager.default
        let suffixes: Set<String> = [
            "json", "start", "attempts", "alerter-pid", "watch-pid", "callback-lock", "codex-owner",
            "claude-owner",
            "title", "round", "native-notice.json", "legacy-cleared", "marker.json",
        ]
        for directory in Set([event.sessionDirectory, event.rateDirectory]) {
            let stamp = directory + "/.pruned"
            if let attrs = try? fm.attributesOfItem(atPath: stamp),
                let pruned = attrs[.modificationDate] as? Date,
                (0..<3600).contains(now - pruned.timeIntervalSince1970)
            {
                continue
            }
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            // `now` is the event's clock, which a test may set; the stamp follows it.
            if (try? PrivateFile.write("", to: stamp)) != nil {
                try? fm.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: now)], ofItemAtPath: stamp)
            }
            for name in names {
                let file = directory + "/" + name
                let ownSessionFile = suffixes.contains { suffix in
                    name.hasSuffix("." + suffix)
                        && RequestCodec.isValidSessionID(String(name.dropLast(suffix.count + 1)))
                }
                guard let attrs = try? fm.attributesOfItem(atPath: file),
                    attrs[.type] as? FileAttributeType == .typeRegular,
                    let modified = attrs[.modificationDate] as? Date,
                    now - modified.timeIntervalSince1970 > 7 * 86400,
                    name.hasPrefix("ghostty-notify-")
                        || ownSessionFile
                else { continue }
                remove(file)
            }
        }
    }
}
