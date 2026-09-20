import Darwin
import Foundation

private struct ExternalNotice: Codable {
    var token: String
    var round: String
    var postedAt: Double
    var executable: String
    var childPID: Int32?
    var childBirth: String?
}

/// Native display-only fallback for terminal-notifier. No click command or
/// long-lived focus watcher is installed. The next prompt removes the group.
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
    private func remove(executable: String, event: HookEvent) async {
        guard
            let child = try? launcher.start(
                executable: executable, arguments: ["-remove", group(event)])
        else { return }
        // Withdrawal is cleanup: let this bounded command finish even when
        // the delivery task was cancelled while its banner was visible.
        _ = await Task { await child.result(timeout: 2) }.value
    }
    private func stop(pid: Int32?, birth: String?, event: HookEvent, executable: String) {
        guard let pid, pid > 1, pid != getpid(), let process = inspector.process(pid),
            birth == nil || process.birth == birth
        else { return }
        let args = inspector.arguments(pid)
        let valid =
            URL(fileURLWithPath: process.executable).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
            && zip(args, args.dropFirst()).contains { $0 == "-group" && $1 == group(event) }
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
            await remove(executable: record.executable, event: event)
            stop(
                pid: record.childPID, birth: record.childBirth, event: event,
                executable: record.executable)
            try? FileManager.default.removeItem(atPath: path(event, "native-notice.json"))
        }
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
            postedAt: clock.now(), executable: executable,
            childPID: child.pid, childBirth: inspector.process(child.pid)?.birth)
        do {
            try PrivateFile.write(
                JSONEncoder().encode(record), to: path(event, "native-notice.json"))
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
        await remove(executable: record.executable, event: event)
        stop(
            pid: record.childPID, birth: record.childBirth, event: event,
            executable: record.executable)
        try? FileManager.default.removeItem(atPath: path(event, "native-notice.json"))
    }
}
