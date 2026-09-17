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
    private let automation: any TerminalAutomationProviding
    private let writer: any TerminalTitleWriting
    private let clock: any HookClockProviding
    private let clear: @Sendable (HookEvent) async -> Void
    private let log: @Sendable (String) -> Void

    public init(
        automation: any TerminalAutomationProviding,
        writer: any TerminalTitleWriting = MacTerminalTitleWriter(),
        clock: any HookClockProviding = SystemHookClock(),
        clear: @escaping @Sendable (HookEvent) async -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.automation = automation
        self.writer = writer
        self.clock = clock
        self.clear = clear
        self.log = log
    }

    private func path(_ event: HookEvent, _ suffix: String) -> String {
        event.sessionDirectory + "/" + event.sessionID + "." + suffix
    }
    private func current(_ event: HookEvent) -> Bool {
        DiskRoundJournal.read(path(event, "round")) == event.roundID
    }
    private func cached(_ event: HookEvent, pid: pid_t?) -> Record? {
        guard let data = FileManager.default.contents(atPath: path(event, "json")),
            let record = try? JSONDecoder().decode(Record.self, from: data),
            pid == nil || record.ghosttyPID == pid.map(String.init)
        else { return nil }
        return record
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
        guard let lease = DirectoryLease.acquire(path(event, "lock"), timeout: 0, staleAfter: 120)
        else { return await existing(event) }
        defer { lease.release() }
        if let record = cached(event, pid: pid) {
            return record.tabID.isEmpty ? nil : record.tabID
        }

        let marker = "__\(event.source.rawValue)_TAB_MARKER_\(event.sessionID)__"
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
            do { before = try await automation.tabs() } catch {
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
            do { try writer.write(title: marker, tty: tty) } catch {
                // A short write can fail after part of the OSC packet reached
                // the terminal. Attempt recovery even on this path.
                _ = await restore(
                    before: before, marker: marker, target: nil, tty: tty,
                    markerMayBePartial: true)
                log("cannot write terminal marker: \(error)")
                return nil
            }
            // Restoration runs even when sleep/lookup fails or a newer prompt
            // cancels us. Never put a cancellation check ahead of restoration.
            do {
                try await clock.sleep(seconds: 0.15)
                result = try await automation.tabs().first(where: { $0.title == marker })?.id
            } catch { result = nil }
            let restored = await restore(before: before, marker: marker, target: result, tty: tty)
            guard restored, current(event), !Task.isCancelled else { return nil }
            if result != nil { break }
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
        before: [TerminalTab], marker: String, target: String?, tty: String,
        markerMayBePartial: Bool = false
    ) async -> Bool {
        var target = target
        if target == nil {
            do {
                target = try await automation.tabs().first(where: { $0.title == marker })?.id
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
            if before.count == 1 {
                do {
                    try writer.write(title: before[0].title, tty: tty)
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
            try writer.write(title: original.title, tty: tty)
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
