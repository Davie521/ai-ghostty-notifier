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
        // Every record below is this Claude process's own: one from another
        // process (a resumed session) is no record at all.
        let owner = event.owner ?? ""
        func own<Record: OwnedRecord>(_ record: Record?) -> Record? {
            record.flatMap { !owner.isEmpty && $0.owner == owner ? $0 : nil }
        }
        // The current turn, as its prompt recorded it.
        let turn = own(record(path(event, "turn")).flatMap(TurnRecord.init))
        // A message sent while a turn runs carries that turn's prompt id: it
        // joins the turn, which keeps its start and its baseline, whatever
        // it looks like (a report pasted mid-turn too). A report that wakes
        // the session begins a turn of its own, with an id of its own.
        let joinsTurn =
            event.kind == .prompt && waits
            && event.payload.promptID.map { !$0.isEmpty && $0 == turn?.prompt } ?? false
        // A report from work the paused round waits on: the round goes on,
        // and keeping its start makes its completion count the wait. Any
        // other report, or one pasted by a person, does not.
        let pause = own(record(path(event, "paused")).flatMap(PauseRecord.init)).flatMap {
            !$0.round.isEmpty && $0.round == turn?.round ? $0 : nil
        }
        let resumes =
            event.kind == .prompt && waits
            && event.reportedTask.map { pause?.tasks.contains($0) ?? false } ?? false
        // Another task's report right after a Stop that went out continues the
        // same run: it keeps the round, so that completion, perhaps not yet
        // delivered, stays current rather than being cancelled by it.
        let continuesRun =
            event.kind == .prompt && waits && event.reportedTask != nil && !resumes && valid
            && !owner.isEmpty && stoppedRound(event) == StoppedRecord(round: old, owner: owner)
        // A new round's baseline goes before the round is published: a hook
        // stopped in between leaves none, not the last round's.
        if event.kind == .prompt, claude, !(resumes || joinsTurn) {
            discard(path(event, "background-earlier"))
        }
        event.roundID = (event.kind == .prompt && !continuesRun) || !valid ? UUID().uuidString : old
        if event.roundID != old, !write(event.roundID, path(event, "round")) {
            throw CocoaError(.fileWriteUnknown)
        }
        if resumes, let pause, let task = event.reportedTask {
            // This report is in; the others the round waits on still come.
            let left = PauseRecord(
                owner: owner, round: pause.round, tasks: pause.tasks.filter { $0 != task })
            if !write(left.text, path(event, "paused")) { discard(path(event, "paused")) }
        }
        if event.kind == .prompt {
            var logical = resumes ? turn?.round : nil
            if !(resumes || joinsTurn) { logical = try startRound(event, firstSeen: old.isEmpty) }
            if claude, !joinsTurn {
                let next = TurnRecord(
                    owner: owner, prompt: event.payload.promptID ?? "", round: logical ?? "")
                if owner.isEmpty || !write(next.text, path(event, "turn")) {
                    discard(path(event, "turn"))
                }
            }
        } else if event.kind == .preTool, claude,
            !FileManager.default.fileExists(atPath: path(event, "start"))
        {
            guard write(Self.clock(at: event.occurredAt), path(event, "start")) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        if event.kind == .preTool, claude {
            // A tool used under no known turn stands for one that may never
            // reach its Stop. Lost track of the turns, nothing running can be
            // told apart.
            let used = event.payload.promptID ?? "?"
            if let turns = entries("turns", event) {
                if !turns.contains(used),
                    !write((turns + [used]).joined(separator: "\n"), path(event, "turns"))
                {
                    forget(event)
                }
            } else {
                forget(event)
            }
        }
        if event.kind == .stop, claude {
            let turns = entries("turns", event)
            // A turn that used tools and never reached its Stop was
            // interrupted, and what it left running is not known to be this
            // round's: it may be a server. The round's baseline no longer tells
            // its work apart, for this Stop or any later one of the round.
            // Two turns are proof enough without this Stop's own id; without
            // that id, the one its prompt recorded; with neither, the turns
            // cannot be matched to it.
            let stopping =
                event.payload.promptID ?? turn.map(\.prompt).flatMap { $0.isEmpty ? nil : $0 }
            let interrupted =
                turns.map { turns in
                    Set(turns).count > 1 || turns.contains("?")
                        || (stopping.map { id in turns.contains { $0 != id } } ?? !turns.isEmpty)
                } ?? true
            if interrupted {
                discard(path(event, "background-earlier"))
                // Should that fail, the turn on record no longer names it.
                if let turn, !turn.round.isEmpty {
                    let retired = TurnRecord(owner: owner, prompt: turn.prompt, round: "")
                    if !write(retired.text, path(event, "turn")) { discard(path(event, "turn")) }
                }
            }
            var paused = false
            if let tasks = event.payload.backgroundTasks,
                event.payload.backgroundUnidentified != true
            {
                let earlierPath = path(event, "background-earlier")
                // The round's baseline: this process's, and the one this round
                // began with, not one a failed write or removal left behind.
                var baseline =
                    interrupted
                    ? nil
                    : own(record(earlierPath).flatMap(Snapshot.init)).flatMap {
                        !$0.mark.isEmpty && $0.mark == turn?.round ? $0 : nil
                    }
                // A Stop of another prompt than the turn on record (that
                // prompt's hook did not run): the baseline is not its round's.
                if let id = event.payload.promptID, let recorded = turn?.prompt,
                    !recorded.isEmpty, recorded != id
                {
                    baseline = nil
                }
                // A kind left out now is the one on record: in the round's
                // baseline, or in this process's last snapshot.
                let kinds = (lastSnapshot(event, owner: owner)?.kinds ?? [:]).merging(
                    baseline?.kinds ?? [:]
                ) { _, round in round }
                let tasks = tasks.map { BackgroundTask(id: $0.id, type: $0.type ?? kinds[$0.id]) }
                // The next round's baseline, kept even when empty and whether
                // or not waiting is on, for this process only, under a mark
                // of its own that the record of the latest one must match.
                let snapshot = Snapshot(
                    owner: owner, mark: UUID().uuidString,
                    tasks: tasks.filter(\.mayWakeSession).map { ($0.id, $0.type ?? "") })
                if owner.isEmpty || !write(snapshot.mark, path(event, "background-mark"))
                    || !write(snapshot.text, path(event, "background"))
                {
                    dropSnapshot(event)
                }
                var newWork: [BackgroundTask] = []
                if waits, let before = baseline {
                    let judged = before.judge(tasks)
                    newWork = judged.new
                    // Excused once as an earlier launcher's, excused for the
                    // rest of the round, even after that launcher ends.
                    if !judged.excused.isEmpty {
                        baseline?.tasks += judged.excused.map { ($0.id, $0.type ?? "") }
                        // Unrecorded, the round cannot be held on it.
                        if baseline.map({ write($0.text, earlierPath) }) != true {
                            discard(earlierPath)
                            newWork = []
                        }
                    }
                }
                if !newWork.isEmpty {
                    // Recorded here, under the lock, and not by whoever
                    // consumes the event later: a report that wakes the
                    // session may come first. It names the work waited on,
                    // whose reports alone resume the round. After a Stop of
                    // this round that went out, a new generation, so that
                    // Stop, maybe not yet consumed, cannot announce the round
                    // or clear its start. Otherwise the round keeps its id,
                    // which its prompt, maybe not yet consumed, still needs.
                    // Unrecorded, it is not held.
                    // With the work whose reports have yet to come, though it
                    // may have ended already.
                    var awaited = pause?.tasks ?? []
                    var seen = Set(awaited)
                    for task in newWork where seen.insert(task.id).inserted {
                        awaited.append(task.id)
                    }
                    let marker = PauseRecord(owner: owner, round: turn?.round ?? "", tasks: awaited)
                        .text
                    if stoppedRound(event).map({ $0.map { $0.round == event.roundID } ?? true })
                        ?? false
                    {
                        let generation = UUID().uuidString
                        if write(generation, path(event, "round")) {
                            event.roundID = generation
                            paused = write(marker, path(event, "paused"))
                        }
                    } else {
                        paused = write(marker, path(event, "paused"))
                    }
                }
                if waits { event.awaitingBackground = paused }
            } else {
                // Nothing is known about what runs now.
                dropSnapshot(event)
                if waits, event.payload.backgroundTasks != nil { event.awaitingBackground = false }
            }
            // Retired only now that the snapshot is settled: a hook stopped
            // before this leaves the turns, not an old snapshot that looks
            // current without them.
            discard(path(event, "turns"))
            if !paused {
                discard(path(event, "paused"))
                // This Stop goes out. Unless that is on record, a later one of
                // the round could not make it stale, so none may be held.
                if !write(
                    StoppedRecord(round: event.roundID, owner: owner).text, path(event, "stopped"))
                {
                    discard(path(event, "stopped"))
                    discard(path(event, "background-earlier"))
                }
            }
            // Decided; the list need not travel to the app.
            event.payload.backgroundTasks = nil
            event.payload.backgroundUnidentified = nil
        }
        let clock = Self.clock(Self.read(path(event, "start")))
        event.startedAt = clock?.value ?? 0
        event.startToken = clock?.token
        return event
    }

    /// A round's clock: when it started, in whole seconds, and an id of its
    /// own, so a clock begun in the same second is still told apart. A
    /// start written before the id existed is the seconds alone.
    static func clock(at time: Double) -> String {
        String(Int(time)) + " " + UUID().uuidString
    }

    static func clock(_ text: String) -> (value: Double, token: String?)? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
            parts[0].utf8.allSatisfy({ (48...57).contains($0) }),
            let value = Double(parts[0]), value.isFinite
        else { return nil }
        guard parts.count == 2 else { return (value, nil) }
        guard !parts[1].isEmpty, parts[1].count <= 64,
            parts[1].utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45
            })
        else { return nil }
        return (value, String(parts[1]))
    }

    /// A prompt that begins a round: its clock starts over, and for Claude its
    /// baseline is what already ran when it began (a dev server left up),
    /// which is not its work. Without a baseline on record from this very
    /// process (a resumed session, one open before this version, a failed
    /// write, a CLI that did not say) the round is never held, and notifies
    /// as before. Returns the id this round's baseline carries.
    private func startRound(_ event: HookEvent, firstSeen: Bool) throws -> String? {
        remove(path(event, "start"))
        if event.source == .codex, !write(Self.clock(at: event.occurredAt), path(event, "start")) {
            throw CocoaError(.fileWriteUnknown)
        }
        guard event.source == .claude else { return nil }
        discard(path(event, "paused"))
        let owner = event.owner ?? ""
        let last = path(event, "background")
        // A session's first prompt comes before its transcript exists: no
        // work of its own can be running yet. Monitors can (a plugin arms
        // them at start), so all of them count as already running. Only for
        // a session not seen before, and only on a confirmed absence: a
        // transcript gone later, or one that cannot be looked at, says
        // nothing about what runs.
        if firstSeen, !owner.isEmpty, let transcript = event.payload.transcriptPath,
            Self.confirmedAbsent(transcript)
        {
            let seed = Snapshot(owner: owner, mark: UUID().uuidString, tasks: [("*", "monitor")])
            if !write(seed.mark, path(event, "background-mark")) || !write(seed.text, last) {
                discard(last)
            }
        }
        let round = UUID().uuidString
        let baseline = path(event, "background-earlier")
        if let snapshot = lastSnapshot(event, owner: owner),
            write(Snapshot(owner: owner, mark: round, tasks: snapshot.tasks).text, baseline)
        {
            return round
        }
        discard(baseline)
        return round
    }

    /// No snapshot is the latest: its mark is retired with it, so one that
    /// could not be removed is not taken for current either.
    private func dropSnapshot(_ event: HookEvent) {
        discard(path(event, "background"))
        if !write(UUID().uuidString, path(event, "background-mark")) {
            discard(path(event, "background-mark"))
        }
    }

    /// This process's latest snapshot: the one the record of the latest
    /// names, not one a failed write or removal left behind.
    private func lastSnapshot(_ event: HookEvent, owner: String) -> Snapshot? {
        guard !owner.isEmpty, let mark = record(path(event, "background-mark")), !mark.isEmpty,
            let snapshot = record(path(event, "background")).flatMap(Snapshot.init),
            snapshot.owner == owner, snapshot.mark == mark
        else { return nil }
        return snapshot
    }

    /// The round whose last Stop went out: none when there is no record, and
    /// `.some(nil)` when there is one that cannot be read.
    private func stoppedRound(_ event: HookEvent) -> StoppedRecord?? {
        let file = path(event, "stopped")
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        return .some(record(file).flatMap(StoppedRecord.init))
    }

    static func confirmedAbsent(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var status = stat()
        return lstat(path, &status) != 0 && errno == ENOENT
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
            // Only the clock this Stop measured from: a turn the round goes on
            // with (another task's report) may have begun one since, even in
            // the same second. Known by its id; a Stop from a hook older than
            // the id, by its value, compared as read (a corrupt start may not
            // fit an integer).
            if let current = Self.clock(Self.read(path(event, "start"))), event.startedAt > 0,
                event.startToken.map({ $0 == current.token })
                    ?? (current.token == nil && current.value == event.startedAt)
            {
                remove(path(event, "start"))
            }
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
            "title", "round",
            "native-notice.json",
            "legacy-cleared", "marker.json",
            "lock.flock", "round-lock.flock", "delivery-lock.flock",
        ]
        // The background-wait records are only ever written to the session
        // directory, which may not be the only thing in the rate directory.
        let sessionOnly: Set<String> = [
            "background", "background-earlier", "background-mark", "paused", "turns", "stopped",
            "turn",
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
                let candidates =
                    directory == event.sessionDirectory ? suffixes.union(sessionOnly) : suffixes
                let ownSessionFile = candidates.contains { suffix in
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

/// A record that belongs to the Claude process that wrote it.
protocol OwnedRecord { var owner: String { get } }

/// What ran when a Claude round began or a Stop came: the process it was seen
/// by and a mark of its own, then one `id<TAB>type` line per task that may
/// wake the session. An id of `*` stands for every task of its type.
struct Snapshot: Equatable, OwnedRecord {
    var owner: String
    var mark: String
    var tasks: [(id: String, type: String)]

    init(owner: String, mark: String = "", tasks: [(id: String, type: String)]) {
        self.owner = owner
        self.mark = mark
        self.tasks = tasks
    }

    init?(_ text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let head = first.split(separator: "\t", omittingEmptySubsequences: false)
        guard (2...3).contains(head.count), head[0] == "owner" else { return nil }
        owner = String(head[1])
        mark = head.count == 3 ? String(head[2]) : ""
        lines.removeFirst()
        var tasks: [(id: String, type: String)] = []
        for line in lines where !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            tasks.append((String(parts[0]), String(parts[1])))
        }
        self.tasks = tasks
    }

    var text: String {
        (["owner\t" + owner + "\t" + mark] + tasks.map { $0.id + "\t" + $0.type })
            .joined(separator: "\n")
    }

    static func == (lhs: Snapshot, rhs: Snapshot) -> Bool { lhs.text == rhs.text }

    /// The kind on record for each task.
    var kinds: [String: String] {
        var kinds: [String: String] = [:]
        for task in tasks where task.id != "*" && !task.type.isEmpty { kinds[task.id] = task.type }
        return kinds
    }

    /// The work in `running` that this round started and that will wake the
    /// session (`new`). A subagent or workflow from before may itself start
    /// shells and monitors, which show in the same list with no sign of whose
    /// they are: while one runs, those are `excused`. Linear in both lists.
    func judge(_ running: [BackgroundTask]) -> (new: [BackgroundTask], excused: [BackgroundTask]) {
        var known: [String: String] = [:]
        var everyOf: Set<String> = []
        for task in tasks {
            if task.id == "*" { everyOf.insert(task.type) } else { known[task.id] = task.type }
        }
        let launchers: Set<String> = ["subagent", "workflow"]
        // One whose kind was never given may be one too.
        // Alive when the round began, it may have started them at any time
        // since, and may have ended by now: the round's own shells and
        // monitors cannot be told from its, and do not count. One whose kind
        // was never given may be one too.
        let launcherBefore = tasks.contains { task in
            task.id != "*" && (task.type.isEmpty || launchers.contains(task.type))
        }
        var new: [BackgroundTask] = []
        var excused: [BackgroundTask] = []
        for task in running
        where task.wakesSession && known[task.id] == nil && !everyOf.contains(task.type ?? "") {
            if launcherBefore && !launchers.contains(task.type ?? "") {
                excused.append(task)
            } else {
                new.append(task)
            }
        }
        return (new, excused)
    }
}

/// The turn a Claude prompt began: the process, the prompt's id, and the id
/// of the round's baseline, so a baseline left over from another round is
/// told apart.
struct TurnRecord: OwnedRecord {
    var owner: String
    var prompt: String
    var round: String

    init(owner: String, prompt: String, round: String) {
        self.owner = owner
        self.prompt = prompt
        self.round = round
    }

    init?(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 3, lines[0].hasPrefix("owner\t"), lines[1].hasPrefix("prompt\t"),
            lines[2].hasPrefix("round\t")
        else { return nil }
        owner = String(lines[0].dropFirst(6))
        prompt = String(lines[1].dropFirst(7))
        round = String(lines[2].dropFirst(6))
    }

    var text: String { "owner\t\(owner)\nprompt\t\(prompt)\nround\t\(round)" }
}

/// A round held on background work: the process, the round's mark (that of
/// its baseline), then the ids of the work whose reports resume it.
struct PauseRecord: OwnedRecord {
    var owner: String
    var round: String
    var tasks: [String]

    init(owner: String, round: String, tasks: [String]) {
        self.owner = owner
        self.round = round
        self.tasks = tasks
    }

    init?(_ text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let head = first.split(separator: "\t", omittingEmptySubsequences: false)
        guard head.count == 3, head[0] == "owner" else { return nil }
        owner = String(head[1])
        round = String(head[2])
        lines.removeFirst()
        tasks = lines.filter { !$0.isEmpty }.map(String.init)
    }

    var text: String { (["owner\t" + owner + "\t" + round] + tasks).joined(separator: "\n") }
}

/// The last Stop that went out: its generation and the process it came from.
struct StoppedRecord: Equatable {
    var round: String
    var owner: String

    init(round: String, owner: String) {
        self.round = round
        self.owner = owner
    }

    init?(_ text: String) {
        let parts = text.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        round = String(parts[0])
        owner = String(parts[1])
    }

    var text: String { round + "\t" + owner }
}
