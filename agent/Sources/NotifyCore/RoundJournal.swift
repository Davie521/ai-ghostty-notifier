import Darwin
import Foundation

public protocol RoundJournalProviding: Sendable {
    func isCurrent(_ event: HookEvent) async -> Bool
    func prepare(_ event: HookEvent) async
    func finish(_ event: HookEvent) async
    func claimRate(_ event: HookEvent, now: Double) async -> Bool
}

/// The plain-text records hook-common.sh kept, so that a cold start or a
/// permission failure can switch backends without losing the start time or
/// opening a second rate-limit bucket.
public actor DiskRoundJournal: RoundJournalProviding {
    public init() {}

    /// Runs in the short-lived native hook before it returns. A queued prompt
    /// must invalidate old work immediately, not when the resident app drains it.
    public func capture(_ input: HookEvent) throws -> HookEvent {
        guard RequestCodec.isValidSessionID(input.sessionID),
            input.sessionDirectory.hasPrefix("/"), input.sessionDirectory != "/"
        else { throw CocoaError(.fileWriteInvalidFileName) }
        try PrivateFile.createDirectory(input.sessionDirectory)
        guard let lease = FileLease.acquire(path(input, "round-lock")) else {
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
        let claude = event.source == .claude
        let waits = claude && event.options.waitBackground
        // A message sent while a turn runs carries that turn's prompt id, under
        // which the turn has used tools: it joins the turn, and the turn keeps
        // its start and what was running before it began.
        let joinsTurn =
            event.kind == .prompt && waits && !event.isInjectedPrompt
            && event.payload.promptID.map { (entries("turns", event) ?? []).contains($0) } ?? false
        // The work a paused round waits on reports back: the round goes on,
        // and keeping its start makes its completion count the wait.
        let resumes =
            event.kind == .prompt && waits && event.isTaskReport && isFile(path(event, "paused"))
        event.roundID = event.kind == .prompt || !valid ? UUID().uuidString : old
        if event.roundID != old, !write(event.roundID, path(event, "round")) {
            throw CocoaError(.fileWriteUnknown)
        }
        if event.kind == .prompt {
            if !(resumes || joinsTurn) { try startRound(event, firstSeen: old.isEmpty) }
        } else if event.kind == .preTool, claude,
            !FileManager.default.fileExists(atPath: path(event, "start"))
        {
            guard write(String(Int(event.occurredAt)), path(event, "start")) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        if event.kind == .preTool, claude {
            // A tool used under no known turn stands for one that may never
            // reach its Stop. Lost track of the turns, nothing running can be
            // told apart.
            let turn = event.payload.promptID ?? "?"
            if let turns = entries("turns", event) {
                if !turns.contains(turn),
                    !write((turns + [turn]).joined(separator: "\n"), path(event, "turns"))
                {
                    forget(event)
                }
            } else {
                forget(event)
            }
        }
        if event.kind == .stop, claude {
            let turns = entries("turns", event)
            discard(path(event, "turns"))
            // Whether this round already had a Stop (another hook made Claude
            // go on); recorded for the next one.
            let stoppedBefore = record(path(event, "stopped")) == event.roundID
            var paused = false
            if let tasks = event.payload.backgroundTasks,
                event.payload.backgroundUnidentified != true
            {
                let running = tasks.filter(\.wakesSession).map(\.id)
                // The next round's baseline, kept even when empty and whether
                // or not waiting is on.
                let snapshot = tasks.filter(\.mayWakeSession).map(\.id)
                if !write(snapshot.joined(separator: "\n"), path(event, "background")) {
                    discard(path(event, "background"))
                }
                // A turn that used tools and never reached its Stop was
                // interrupted, and what it left running is not known to be
                // this round's: it may be a server. Notify as before. Two
                // turns are proof enough without this Stop's own id.
                let interrupted =
                    turns.map { turns in
                        Set(turns).count > 1 || turns.contains("?")
                            || (event.payload.promptID.map { id in turns.contains { $0 != id } }
                                ?? false)
                    } ?? true
                // The round's baseline no longer tells its work apart, for
                // any later Stop of it either.
                if interrupted { discard(path(event, "background-earlier")) }
                if waits, !interrupted, let baseline = record(path(event, "background-earlier")) {
                    let earlier = Set(baseline.split(separator: "\n").map(String.init))
                    if running.contains(where: { !earlier.contains($0) }) {
                        // Recorded here, under the lock, and not by whoever
                        // consumes the event later: a report that wakes the
                        // session may come first. After an earlier Stop of
                        // this round, a new generation, so that Stop, maybe
                        // not yet consumed, cannot announce the round or clear
                        // its start. Otherwise the round keeps its id, which
                        // its prompt, maybe not yet consumed, still needs.
                        // Unrecorded, it is not held.
                        if stoppedBefore {
                            let generation = UUID().uuidString
                            if write(generation, path(event, "round")) {
                                event.roundID = generation
                                paused = write("1", path(event, "paused"))
                            }
                        } else {
                            paused = write("1", path(event, "paused"))
                        }
                    }
                }
                if waits { event.awaitingBackground = paused }
            } else {
                // Nothing is known about what runs now.
                discard(path(event, "background"))
                if waits, event.payload.backgroundTasks != nil { event.awaitingBackground = false }
            }
            if !paused { discard(path(event, "paused")) }
            if !write(event.roundID, path(event, "stopped")) { discard(path(event, "stopped")) }
            // Decided; the list need not travel to the app.
            event.payload.backgroundTasks = nil
            event.payload.backgroundUnidentified = nil
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

    /// A prompt that begins a round: its clock starts over, and for Claude its
    /// baseline is what already ran when it began (a dev server left up),
    /// which is not its work. Without a baseline on record (a session open
    /// before this version or resumed, a failed write, a CLI that did not say)
    /// the round is never held, and notifies as before.
    private func startRound(_ event: HookEvent, firstSeen: Bool) throws {
        remove(path(event, "start"))
        if event.source == .codex, !write(String(Int(event.occurredAt)), path(event, "start")) {
            throw CocoaError(.fileWriteUnknown)
        }
        guard event.source == .claude else { return }
        discard(path(event, "paused"))
        // A session's first prompt comes before its transcript exists: then
        // nothing can be running yet. Only for a session not seen before: a
        // transcript gone later says nothing about what runs.
        let last = path(event, "background")
        if firstSeen, let transcript = event.payload.transcriptPath, !transcript.isEmpty,
            !FileManager.default.fileExists(atPath: transcript), !write("", last)
        {
            discard(last)
        }
        let baseline = path(event, "background-earlier")
        if record(last).map({ write($0, baseline) }) != true { discard(baseline) }
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

    /// A record's text, or nil when there is no such file or it cannot be
    /// read: never an empty stand-in for a failure.
    private func record(_ path: String) -> String? {
        guard isFile(path), let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .newlines)
    }

    /// A record's lines: none when it does not exist, nil when unreadable.
    private func entries(_ suffix: String, _ event: HookEvent) -> [String]? {
        let file = path(event, suffix)
        guard FileManager.default.fileExists(atPath: file) else { return [] }
        return record(file)?.split(separator: "\n").map(String.init)
    }

    /// What runs can no longer be told apart: no round is held until a Stop
    /// records it again.
    private func forget(_ event: HookEvent) {
        discard(path(event, "background"))
        discard(path(event, "background-earlier"))
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

    /// For the background-wait state: files only, as `unlink` never takes a
    /// directory, let alone what is in it.
    private func discard(_ path: String) { _ = unlink(path) }

    private func isFile(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            == .typeRegular
    }

    private func withLock(_ directory: String, _ body: () -> Bool) -> Bool {
        guard let lease = FileLease.acquire(directory) else { return false }
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
            "title", "round", "background", "background-earlier", "paused", "turns", "stopped",
            "native-notice.json",
            "legacy-cleared", "marker.json",
            "lock.flock", "round-lock.flock", "delivery-lock.flock",
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
                // A lock file goes only while nobody holds it.
                if name.hasSuffix(".flock") {
                    FileLease.discard(lockFile: file)
                } else {
                    remove(file)
                }
            }
        }
    }
}
