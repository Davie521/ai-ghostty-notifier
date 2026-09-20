import Darwin
import Foundation

public struct TerminalTab: Equatable, Sendable {
    public var id: String
    public var title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public protocol TerminalAutomationProviding: Sendable {
    func processID() async -> pid_t?
    func tabs() async throws -> [TerminalTab]
    func focus(tabID: String?) async
    /// nil means unknown, not proof that the user left Ghostty.
    func isFrontmost() async -> Bool?
    func selectedTabID() async -> String?
}

public protocol TerminalTitleWriting: Sendable {
    func write(title: String, tty: String) throws
}

public struct MacTerminalTitleWriter: TerminalTitleWriting {
    public init() {}
    public static func packet(_ title: String) -> Data {
        // Untrusted titles must not terminate OSC and inject further escapes.
        let safe = String(
            title.unicodeScalars.filter {
                $0.value >= 32 && $0.value != 127 && $0.value != 0x9c
            })
        return Data(("\u{1B}]2;" + safe + "\u{1B}\\").utf8)
    }
    public func write(title: String, tty: String) throws {
        guard tty.hasPrefix("/dev/"), !tty.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try Self.packet(title).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }
}

/// A whole marker transaction lives here: cache, cross-process lease, snapshot,
/// marker, lookup, restoration and round-scoped publication. No shell helper.
public actor NativeTerminalBinding: TerminalBindingProviding {
    private struct Record: Codable {
        var tabID: String
        var cwd: String?
        var ghosttyPID: String?
        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case cwd
            case ghosttyPID = "ghostty_pid"
        }
    }
    /// What a marker transaction needs in order to be undone by a later
    /// process. Written before the marker, removed once the title is back.
    private struct Outstanding: Codable {
        struct Tab: Codable {
            var id: String
            var title: String
        }
        var marker: String
        var tty: String
        var ghosttyPID: String
        var tabs: [Tab]
    }
    private let automation: any TerminalAutomationProviding
    private let writer: any TerminalTitleWriting
    private let clock: any HookClockProviding
    private let queryTimeout: Double
    private let cancelledQueryTimeout: Double
    private let clear: @Sendable (HookEvent) async -> Void
    private let log: @Sendable (String) -> Void
    /// When this process last abandoned a query. The thread that made it is
    /// still blocked, so asking again can only cost another full timeout.
    private var stalledAt: Double?

    /// How long one abandoned query keeps every session away from the terminal.
    /// Short on purpose: the causes seen so far (an unanswered Automation
    /// prompt, a wedged Ghostty) clear on their own, unlike a denied permission.
    public static let stallBackoff: Double = 60

    public init(
        automation: any TerminalAutomationProviding,
        writer: any TerminalTitleWriting = MacTerminalTitleWriter(),
        clock: any HookClockProviding = SystemHookClock(),
        queryTimeout: Double = 5,
        cancelledQueryTimeout: Double = 1,
        clear: @escaping @Sendable (HookEvent) async -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.automation = automation
        self.writer = writer
        self.clock = clock
        self.queryTimeout = queryTimeout
        self.cancelledQueryTimeout = cancelledQueryTimeout
        self.clear = clear
        self.log = log
    }

    private func path(_ event: HookEvent, _ suffix: String) -> String {
        event.sessionDirectory + "/" + event.sessionID + "." + suffix
    }
    private func current(_ event: HookEvent) -> Bool {
        DiskRoundJournal.read(path(event, "round")) == event.roundID
    }
    private func stallStamp(_ event: HookEvent) -> String {
        event.sessionDirectory + "/applescript-stalled"
    }
    private func recentlyStalled(_ since: Double?) -> Bool {
        since.map { (0..<Self.stallBackoff).contains(clock.now() - $0) } ?? false
    }

    /// Every terminal query goes through here. The provider runs NSAppleScript
    /// in-process, and a blocked send ignores both Task cancellation and the
    /// script's own `with timeout`. On 2026-09-17 that held PreToolUse hooks for
    /// the CLI's full 600-second hook timeout, and left workers hung for hours.
    /// The wait is what gets bounded here; the blocked call itself is abandoned.
    private func snapshot(_ event: HookEvent) async throws -> [TerminalTab] {
        if recentlyStalled(stalledAt) { throw TerminalQueryAbandoned() }
        let automation = self.automation
        do {
            // Restoration runs in cancelled tasks and must still get answers,
            // so cancellation shortens this wait rather than ending it. Without
            // the shorter limit a SIGTERM grace period expires behind a query
            // that will never return, and the marker is left on the tab.
            return try await QueryDeadline.run(
                seconds: queryTimeout, cancelledSeconds: cancelledQueryTimeout
            ) {
                try await automation.tabs()
            }
        } catch let error as TerminalQueryAbandoned where error.cause == .deadline {
            let now = clock.now()
            stalledAt = now
            // Other hook processes cannot see this actor. The stamp is how the
            // next one avoids paying the same timeout for the same condition.
            try? "\(now)\n".write(toFile: stallStamp(event), atomically: true, encoding: .utf8)
            log(
                "terminal query abandoned after \(queryTimeout)s; "
                    + "skipping terminal binding for \(Int(Self.stallBackoff))s")
            throw error
        }
    }
    private func cached(_ event: HookEvent, pid: pid_t?) -> Record? {
        guard let data = FileManager.default.contents(atPath: path(event, "json")),
            let record = try? JSONDecoder().decode(Record.self, from: data),
            pid == nil || record.ghosttyPID == pid.map(String.init)
        else { return nil }
        return record
    }
    private func outstanding(_ event: HookEvent) -> String { path(event, "marker.json") }

    /// A binding marker, this runtime's (`__claude_…`) or the retired shell
    /// hooks' (`__CLAUDE_…`).
    static func isMarker(_ title: String) -> Bool {
        title.hasPrefix("__") && title.hasSuffix("__") && title.contains("_TAB_MARKER_")
    }

    /// What may be written back for a tab whose captured title was `title`.
    /// A marker is never a title, whoever wrote it: a session that died
    /// mid-transaction leaves one behind, and the next session to start in that
    /// tab captures it as its baseline. The empty title stands in for it:
    /// Ghostty then shows its default, and a live TUI sets its own shortly.
    private func restorable(_ title: String) -> String {
        guard Self.isMarker(title) else { return title }
        log("a captured title was another binding's marker; restoring the default title")
        return ""
    }

    /// Undo a marker an earlier attempt could not. That attempt may have been
    /// abandoned mid-lookup, or ended by the process deadline or SIGKILL, with
    /// several tabs open and therefore no way to tell which title was its own.
    /// Must finish before a new baseline is captured: a leftover marker read as
    /// an "original title" would be written back as the restoration.
    ///
    /// False means the terminal could not be asked, so the caller must not go on
    /// to capture a baseline that may contain the marker.
    private func recoverOutstanding(_ event: HookEvent, marker: String, pid: pid_t) async -> Bool {
        guard let data = FileManager.default.contents(atPath: outstanding(event)) else {
            return true
        }
        func discard() { try? FileManager.default.removeItem(atPath: outstanding(event)) }
        // Tab ids belong to one Ghostty process. A record about another one
        // describes nothing we can undo.
        guard let record = try? JSONDecoder().decode(Outstanding.self, from: data),
            record.marker == marker, record.ghosttyPID == String(pid),
            record.tty.hasPrefix("/dev/"), !record.tty.contains("\0")
        else {
            discard()
            return true
        }
        let tabs: [TerminalTab]
        // The record stays for an attempt that can ask.
        do { tabs = try await snapshot(event) } catch { return false }
        // No marker left means the TUI has retitled the tab since; leave that.
        // A tab that already showed the marker when the record was taken has no
        // original title here, and the marker is never written back as one.
        if let stuck = tabs.first(where: { tab in
            tab.title == marker
                && record.tabs.contains { $0.id == tab.id && $0.title != marker }
        }), let original = record.tabs.first(where: { $0.id == stuck.id }) {
            do {
                // The marker went to the terminal the record names, which is not
                // this one when the session was resumed in another tab. A tab
                // still showing the marker is still attached to that terminal.
                try writer.write(title: restorable(original.title), tty: record.tty)
                log("restored a title left behind by an interrupted binding")
            } catch {
                log("terminal restoration failed: \(error)")
                return false
            }
        }
        discard()
        return true
    }

    public func existing(_ event: HookEvent) async -> String? {
        guard let pid = await automation.processID() else { return nil }
        let value = cached(event, pid: pid)?.tabID
        return value?.isEmpty == false ? value : nil
    }
    public func clearLegacy(_ event: HookEvent) async {
        if event.options.clearOnFocus { await clear(event) }
    }
    public func resolve(_ event: HookEvent) async -> String? {
        guard let pid = await automation.processID() else { return nil }
        if let record = cached(event, pid: pid) {
            return record.tabID.isEmpty ? nil : record.tabID
        }
        guard let tty = event.tty, tty.hasPrefix("/dev/"), !tty.contains("\0"), current(event),
            !Task.isCancelled
        else { return nil }
        let sentinel = event.sessionDirectory + "/applescript-unavailable"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: sentinel),
            let modified = attrs[.modificationDate] as? Date,
            clock.now() - modified.timeIntervalSince1970 < 86400
        {
            return nil
        }
        try? FileManager.default.removeItem(atPath: sentinel)
        if recentlyStalled(Double(DiskRoundJournal.read(stallStamp(event)))) { return nil }
        let stallsBefore = stalledAt
        guard let lease = DirectoryLease.acquire(path(event, "lock"), timeout: 0, staleAfter: 120)
        else { return await existing(event) }
        defer { lease.release() }
        if let record = cached(event, pid: pid) {
            return record.tabID.isEmpty ? nil : record.tabID
        }

        let marker = "__\(event.source.rawValue)_TAB_MARKER_\(event.sessionID)__"
        guard await recoverOutstanding(event, marker: marker, pid: pid) else { return nil }
        let retries: [Double]
        if let value = event.settings["GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS"] {
            let words = value.split(whereSeparator: \.isWhitespace)
            let numbers = words.compactMap { Double($0) }
            retries =
                numbers.count == words.count && numbers.allSatisfy({ $0.isFinite && $0 >= 0 })
                ? Array(numbers.prefix(8)) : []
        } else {
            retries = event.source == .codex ? [0.5, 1, 2, 3] : []
        }
        var result: String?
        let deadline = clock.now() + 20
        for delay in [0] + retries {
            guard current(event), !Task.isCancelled, clock.now() + delay < deadline else {
                return nil
            }
            do { try await clock.sleep(seconds: delay) } catch { return nil }
            let before: [TerminalTab]
            do { before = try await snapshot(event) } catch {
                // Don't disable binding for a day after an ordinary timeout
                // or an app restart. Only permission/unsupported-suite errors
                // are evidence for the negative capability cache.
                if current(event),
                    [-1743, -1708, -2741, CocoaError.fileReadNoPermission.rawValue]
                        .contains((error as NSError).code)
                {
                    try? Data("unavailable\n".utf8).write(
                        to: URL(fileURLWithPath: sentinel), options: .atomic)
                }
                log("terminal snapshot unavailable: \(error)")
                return nil
            }
            guard !before.isEmpty, current(event), !Task.isCancelled else { return nil }
            // A marker already on show has lost its record. It may sit in a tab
            // this session has since left, so it says nothing about this
            // terminal: such a tab is neither bound nor accepted as the answer
            // below. A live TUI retitles its own tab, so the one tab that does
            // not shed a stale marker is the one the session is no longer in.
            let stale = Set(before.filter { $0.title == marker }.map(\.id))
            if !stale.isEmpty { log("ignoring a leftover marker on \(stale.count) tab(s)") }
            let record = Outstanding(
                marker: marker, tty: tty, ghosttyPID: String(pid),
                tabs: before.map { .init(id: $0.id, title: $0.title) })
            guard let journal = try? JSONEncoder().encode(record),
                FileManager.default.createFile(
                    atPath: outstanding(event), contents: journal,
                    attributes: [.posixPermissions: 0o600])
            else {
                // No way to undo it later means no marker now.
                log("cannot record the marker transaction; binding skipped")
                return nil
            }
            do { try writer.write(title: marker, tty: tty) } catch {
                // A short write can fail after part of the OSC packet reached
                // the terminal. Attempt recovery even on this path.
                if await restore(
                    event, before: before, marker: marker, target: nil, tty: tty,
                    markerMayBePartial: true)
                {
                    try? FileManager.default.removeItem(atPath: outstanding(event))
                }
                log("cannot write terminal marker: \(error)")
                return nil
            }
            // Restoration runs even when sleep/lookup fails or a newer prompt
            // cancels us. Never put a cancellation check ahead of restoration.
            do {
                try await clock.sleep(seconds: 0.15)
                result = try await snapshot(event).first(where: {
                    $0.title == marker && !stale.contains($0.id)
                })?.id
            } catch { result = nil }
            let restored = await restore(
                event, before: before, marker: marker, target: result, tty: tty)
            if restored { try? FileManager.default.removeItem(atPath: outstanding(event)) }
            guard restored, current(event), !Task.isCancelled else { return nil }
            if result != nil { break }
            // A stall says nothing about this session's marker. Counting it as
            // a missed marker would let three machine-wide hiccups disable the
            // binding for good.
            if stalledAt != stallsBefore { return nil }
        }
        guard current(event), !Task.isCancelled, await automation.processID() == pid,
            let journalLease = DirectoryLease.acquire(path(event, "round-lock"))
        else { return nil }
        defer { journalLease.release() }
        guard current(event) else { return nil }
        if let result {
            guard publish(event, tab: result, pid: pid) else { return nil }
            try? FileManager.default.removeItem(atPath: path(event, "attempts"))
        } else {
            let attempts =
                min(2, max(0, Int(DiskRoundJournal.read(path(event, "attempts"))) ?? 0)) + 1
            if attempts >= 3 {
                publish(event, tab: "", pid: pid)
                try? FileManager.default.removeItem(atPath: path(event, "attempts"))
            } else {
                try? "\(attempts)\n".write(
                    toFile: path(event, "attempts"), atomically: true, encoding: .utf8)
            }
        }
        return result
    }

    private func restore(
        _ event: HookEvent, before: [TerminalTab], marker: String, target: String?, tty: String,
        markerMayBePartial: Bool = false
    ) async -> Bool {
        var target = target
        // Tabs that showed the marker before it was written are not ours, and
        // their captured "title" is the marker itself.
        let stale = Set(before.filter { $0.title == marker }.map(\.id))
        if target == nil {
            do {
                target = try await snapshot(event).first(where: {
                    $0.title == marker && !stale.contains($0.id)
                })?.id
                // A successful query with no marker means the TUI replaced it
                // already; do not overwrite that newer title during recovery.
                // After a failed write, absence of the complete marker is not
                // evidence of a TUI redraw. Still recover the known sole title.
                if target == nil, !markerMayBePartial { return true }
            } catch {
                // Retry recovery below, without skipping cleanup on cancellation.
            }
        }
        guard let target else {
            // If only one title was captured there is no ambiguity, even when
            // the query failed. Otherwise don't guess and retitle another tab.
            if before.count == 1, stale.isEmpty {
                do {
                    try writer.write(title: restorable(before[0].title), tty: tty)
                    return true
                } catch { log("terminal restoration failed: \(error)") }
            }
            log("could not resolve marker for title restoration")
            return false
        }
        guard let original = before.first(where: { $0.id == target }) else {
            log("marker tab was not in the original snapshot")
            return false
        }
        do {
            try writer.write(title: restorable(original.title), tty: tty)
            return true
        } catch {
            log("terminal restoration failed: \(error)")
            return false
        }
    }

    @discardableResult private func publish(_ event: HookEvent, tab: String, pid: pid_t?) -> Bool {
        let record = Record(tabID: tab, cwd: event.payload.cwd, ghosttyPID: pid.map(String.init))
        guard let data = try? JSONEncoder().encode(record) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path(event, "json")), options: .atomic)
            return true
        } catch {
            log("cannot publish terminal binding: \(error)")
            return false
        }
    }
}
