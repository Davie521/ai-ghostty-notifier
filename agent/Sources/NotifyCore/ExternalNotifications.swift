import Darwin
import Foundation

private struct ExternalNotice: Codable {
    var token: String
    var round: String
    var postedAt: Double
    var executable: String
    var modern: Bool
    var childPID: Int32?
    var childBirth: String?
}

/// Native display-only fallback for terminal-notifier. No click command or
/// long-lived focus watcher is installed. The next prompt removes the group.
/// Legacy alerter support exists only to clean up pre-migration notifications.
public actor ExternalNotifications {
    private let launcher: any CommandLaunching
    private let inspector: any ProcessInspecting
    private let signaller: any ProcessSignalling
    private let clock: any HookClockProviding
    private let log: @Sendable (String) -> Void
    public init(
        automation: any TerminalAutomationProviding,
        launcher: any CommandLaunching = NativeCommandLauncher(),
        inspector: any ProcessInspecting = MacProcessInspector(),
        signaller: any ProcessSignalling = MacProcessSignaller(),
        clock: any HookClockProviding = SystemHookClock(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.launcher = launcher
        self.inspector = inspector
        self.signaller = signaller
        self.clock = clock
        self.log = log
    }
    private func path(_ event: HookEvent, _ suffix: String) -> String {
        event.sessionDirectory + "/" + event.sessionID + "." + suffix
    }
    private func current(_ event: HookEvent) -> Bool {
        DiskRoundJournal.read(path(event, "round")) == event.roundID
    }
    private func group(_ event: HookEvent) -> String {
        let prefix =
            event.settings["GHOSTTY_NOTIFY_GROUP_PREFIX"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (event.source == .codex ? "codex-ghostty-notify" : "ghostty-notify")
        return prefix + "-" + event.sessionID
    }
    private func notice(_ event: HookEvent) -> ExternalNotice? {
        FileManager.default.contents(atPath: path(event, "native-notice.json"))
            .flatMap { try? JSONDecoder().decode(ExternalNotice.self, from: $0) }
    }
    private func owns(_ event: HookEvent, _ token: String) -> Bool { notice(event)?.token == token }
    private func alerter(_ event: HookEvent) -> String? {
        let value =
            event.settings["GHOSTTY_NOTIFY_ALERTER"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ExecutableSearch.find("alerter", event: event)
        return value.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }
    private func modern(_ executable: String) async -> Bool {
        guard let child = try? launcher.start(executable: executable, arguments: ["--help"]) else {
            return false
        }
        return await child.result(timeout: 2).output.contains("--close-label")
    }
    private func remove(executable: String, modern: Bool, event: HookEvent) async {
        guard
            let child = try? launcher.start(
                executable: executable,
                arguments: [modern ? "--remove" : "-remove", group(event)])
        else { return }
        // Withdrawal is cleanup: let this bounded command finish even when
        // the delivery task was cancelled while its banner was visible.
        _ = await Task { await child.result(timeout: 2) }.value
    }
    private func stop(
        pid: Int32?, birth: String?, event: HookEvent, watcher: Bool = false,
        executable: String? = nil
    ) {
        guard let pid, pid > 1, pid != getpid(), let process = inspector.process(pid),
            birth == nil || process.birth == birth
        else { return }
        let args = inspector.arguments(pid)
        let valid: Bool
        if watcher {
            valid =
                args.contains {
                    URL(fileURLWithPath: $0).lastPathComponent == "ghostty-notify-clear.sh"
                }
                && zip(args, args.dropFirst()).contains { $0 == "--watch" && $1 == event.sessionID }
        } else {
            let sameExecutable =
                executable.map {
                    URL(fileURLWithPath: process.executable).resolvingSymlinksInPath().path
                        == URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                } ?? (URL(fileURLWithPath: process.executable).lastPathComponent == "alerter")
            valid =
                sameExecutable
                && zip(args, args.dropFirst()).contains {
                    ($0 == "--group" || $0 == "-group") && $1 == group(event)
                }
        }
        // Re-read birth immediately before signalling: never trust a stale PID
        // file or a substring match on another session's command line.
        if valid, inspector.process(pid)?.birth == process.birth { signaller.terminate(pid) }
    }

    public func clear(_ event: HookEvent, force: Bool = false) async {
        guard force || event.options.clearOnFocus, current(event),
            let lease = DirectoryLease.acquire(path(event, "delivery-lock"), timeout: 5)
        else { return }
        defer { lease.release() }
        guard current(event) else { return }
        if let record = notice(event) {
            // Same-round Notification may already have overtaken this prompt.
            guard force || (record.round != event.roundID && record.postedAt <= event.occurredAt)
            else { return }
            await remove(executable: record.executable, modern: record.modern, event: event)
            stop(
                pid: record.childPID, birth: record.childBirth, event: event,
                executable: record.executable)
            try? FileManager.default.removeItem(atPath: path(event, "native-notice.json"))
        }
        await clearLegacy(event)
    }

    private func clearLegacy(_ event: HookEvent) async {
        let pidFile = path(event, "alerter-pid")
        let stamp = path(event, "legacy-cleared")
        let legacyPIDExists = ["alerter-pid", "watch-pid"].contains {
            FileManager.default.fileExists(atPath: path(event, $0))
        }
        if !legacyPIDExists, FileManager.default.fileExists(atPath: stamp) { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: pidFile),
            let date = attrs[.modificationDate] as? Date,
            date.timeIntervalSince1970 > event.occurredAt
        {
            return
        }
        for suffix in ["watch-pid", "alerter-pid"] {
            stop(
                pid: Int32(DiskRoundJournal.read(path(event, suffix))), birth: nil,
                event: event, watcher: suffix == "watch-pid")
            try? FileManager.default.removeItem(atPath: path(event, suffix))
        }
        // terminal-notifier never wrote a PID. Check both legacy senders even
        // when there is no PID file, but only once per migrated session; an absent group
        // is a no-op. All calls are bounded and receive EOF on stdin.
        if let executable = alerter(event) {
            let dialect = await modern(executable)
            await remove(executable: executable, modern: dialect, event: event)
        }
        if let executable = ExecutableSearch.find("terminal-notifier", event: event) {
            await remove(executable: executable, modern: false, event: event)
        }
        try? "cleared\n".write(toFile: stamp, atomically: true, encoding: .utf8)
    }

    public func deliver(_ request: NotifyRequest, event: HookEvent) async {
        guard !Task.isCancelled, current(event), clock.now() < event.expiresAt else { return }
        guard let executable = ExecutableSearch.find("terminal-notifier", event: event) else {
            log("no usable notification backend; install/authorize the native agent")
            return
        }
        guard let lease = DirectoryLease.acquire(path(event, "delivery-lock"), timeout: 5) else {
            return
        }
        guard !Task.isCancelled, current(event), clock.now() < event.expiresAt else {
            lease.release()
            return
        }
        if let old = notice(event) {
            stop(pid: old.childPID, birth: old.childBirth, event: event, executable: old.executable)
        }
        func value(_ text: String) -> String { String(text.drop(while: { $0 == "-" })) }
        var args = [
            "-title", value(request.title), "-subtitle", value(request.subtitle),
            "-message", value(request.body), "-group", group(event),
        ]
        if let sound = request.sound { args += ["-sound", sound] }
        let child: any RunningCommand
        do { child = try launcher.start(executable: executable, arguments: args) } catch {
            lease.release()
            log("notification backend failed to launch: \(error)")
            return
        }
        let record = ExternalNotice(
            token: UUID().uuidString, round: event.roundID,
            postedAt: clock.now(), executable: executable, modern: false,
            childPID: child.pid, childBirth: inspector.process(child.pid)?.birth)
        do {
            try JSONEncoder().encode(record).write(
                to: URL(fileURLWithPath: path(event, "native-notice.json")), options: .atomic)
        } catch {
            child.cancel()
            lease.release()
            _ = await child.result(timeout: 1)
            log("cannot track external notification: \(error)")
            return
        }
        lease.release()
        // The backend exits after posting. Even TIMEOUT=0 must not leave a
        // worker behind; only the resident offers expiry and focus clearing.
        let result = await child.result(timeout: 5)
        if Task.isCancelled || result.status != 0 {
            await withdraw(event, record: record)
            if !Task.isCancelled { log("terminal-notifier failed; no focus watcher was started") }
        }
        // Keep successful delivery bookkeeping for the next prompt. Never
        // interpret backend stdout as a click or invoke terminal automation.
    }

    private func withdraw(_ event: HookEvent, record: ExternalNotice) async {
        guard let lease = DirectoryLease.acquire(path(event, "delivery-lock"), timeout: 5) else {
            return
        }
        defer { lease.release() }
        guard owns(event, record.token) else { return }
        await remove(executable: record.executable, modern: record.modern, event: event)
        stop(
            pid: record.childPID, birth: record.childBirth, event: event,
            executable: record.executable)
        try? FileManager.default.removeItem(atPath: path(event, "native-notice.json"))
    }
}
