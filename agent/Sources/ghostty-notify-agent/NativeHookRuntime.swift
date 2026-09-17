import AppKit
import Darwin
import Foundation
import NotifyCore

/// All hook modes live in the already-shipped app executable. Only work whose
/// timing depends on the caller (intake, TTY, round capture, Claude binding)
/// runs before the hook returns. Everything else goes to the resident app or
/// a bounded native worker; neither route invokes the old shell helpers.
/// Display-only fallback never leaves a focus watcher, including TIMEOUT=0.
@MainActor
enum NativeHookRuntime {
    static func readInput() -> Data {
        guard isatty(STDIN_FILENO) == 0 else { return Data() }
        var data = Data()
        var oversized = false
        while let chunk = try? FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
            if data.count + chunk.count <= 8 * 1024 * 1024, !oversized {
                data.append(chunk)
            } else {
                data.removeAll()
                oversized = true
            }
        }
        if oversized { diagnostic("hook payload exceeds 8 MiB; event ignored") }
        return data
    }
    static func diagnostic(_ message: String) {
        FileHandle.standardError.write(Data(("ghostty-notify: " + message + "\n").utf8))
    }
    private static func logger(_ paths: AgentPaths) -> @Sendable (String) -> Void {
        { AgentLog.append($0, to: paths.log) }
    }
    private static func dependencies(paths: AgentPaths) -> (
        NativeTerminalBinding, ExternalNotifications
    ) {
        let external = ExternalNotifications(
            automation: MacTerminalAutomation(), log: logger(paths))
        let binding = NativeTerminalBinding(
            automation: MacTerminalAutomation(),
            clear: { await external.clear($0) }, log: logger(paths))
        return (binding, external)
    }

    static func hook(
        arguments: [String], input: Data, environment: [String: String], paths: AgentPaths
    ) async {
        guard let sourceName = arguments.first, let source = HookSource(rawValue: sourceName) else {
            diagnostic("usage: --hook <claude|codex> [event]")
            return
        }
        do {
            let hooks =
                environment["GHOSTTY_NOTIFY_HOOKS_DIR"] ?? environment["CLAUDE_PLUGIN_ROOT"].map {
                    $0 + "/hooks"
                } ?? ""
            guard
                let parsed = try HookIntake.parse(
                    data: input, source: source,
                    expectedEvent: arguments.dropFirst().first, environment: environment,
                    hooksDirectory: hooks)
            else { return }
            let journal = DiskRoundJournal()
            let event = try await journal.capture(parsed)
            await journal.prepare(event)
            guard !Task.isCancelled else { return }
            if event.kind == .preTool {
                // Returning early would let Claude redraw while the OSC marker
                // is outstanding. Always await restoration before exiting.
                let (binding, _) = dependencies(paths: paths)
                _ = await binding.resolve(event)
                return
            }
            let transport = HookTransport(paths: paths)
            let app = HookTransport.application(event: event, home: paths.home)
            if app != nil, transport.acceptsNativeHooks,
                event.kind == .prompt || (event.options.prefersResident && transport.authorized)
            {
                try transport.queue(.hookEvent(event))
                return
            }
            // Do not claim delivery while a cold/denied agent cannot post.
            // Starting it is best-effort for the NEXT event, not an ack.
            if let app, transport.runningPID == nil { launch(application: app) }
            try spawnWorker(event)
        } catch {
            diagnostic("native hook failed: \(error)")
            AgentLog.append("native hook failed: \(error)", to: paths.log)
        }
    }

    static func worker(input: Data, paths: AgentPaths) async {
        do {
            let event = try HookEvent.decode(input)
            guard event.kind != .preTool else { return }
            let (binding, external) = dependencies(paths: paths)
            let transport = HookTransport(paths: paths)
            var delivery: Task<Void, Never>?
            let processor = HookProcessor(
                binding: binding,
                onPrompt: { event, tab in
                    // Old versions cannot interpret raw events. Keep their v1
                    // anchor/dismiss protocol during an in-place upgrade.
                    guard HookTransport.application(event: event, home: paths.home) != nil,
                        transport.runningPID != nil
                    else { return }
                    if let tab {
                        try? transport.queue(
                            .anchor(sessionID: event.sessionID, tabID: tab, source: event.source))
                    }
                    if event.options.clearOnFocus {
                        try? transport.queue(
                            .dismiss(sessionID: event.sessionID, source: event.source))
                    }
                },
                onNotify: { event, request in
                    delivery = Task {
                        if event.options.prefersResident,
                            HookTransport.application(event: event, home: paths.home) != nil,
                            transport.authorized
                        {
                            do {
                                try transport.queue(.notify(request))
                                return
                            } catch {
                                AgentLog.append("native spool failed: \(error)", to: paths.log)
                            }
                        }
                        await external.deliver(request, event: event)
                    }
                }, log: { AgentLog.append($0, to: paths.log) })
            await withTaskCancellationHandler {
                await processor.receive(event).value
            } onCancel: {
                // The processor owns its per-event tasks. Ask it to cancel
                // them, then the operation above awaits their cleanup.
                Task { await processor.shutdown() }
            }
            if let delivery {
                await withTaskCancellationHandler {
                    await delivery.value
                } onCancel: {
                    delivery.cancel()
                }
            }
        } catch { AgentLog.append("native worker rejected input: \(error)", to: paths.log) }
    }

    private static func spawnWorker(_ event: HookEvent) throws {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-worker-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        try input.write(contentsOf: JSONEncoder().encode(event))
        try input.seek(toOffset: 0)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--worker"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The child inherited an open descriptor, so unlinking the private
        // payload now is safe. No named spool containing prompts is left over.
    }

    private static func launch(application: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: application), configuration: config)
    }

    static func utility(
        mode: String, sessionID: String, environment: [String: String], paths: AgentPaths
    ) async {
        guard RequestCodec.isValidSessionID(sessionID), paths.home.hasPrefix("/"),
            paths.home != "/", !paths.home.contains("\0")
        else { return }
        func nonempty(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        let source =
            HookSource(rawValue: environment["GHOSTTY_NOTIFY_PROCESS_NAME"] ?? "claude") ?? .claude
        var directory =
            nonempty("GHOSTTY_NOTIFY_SESSION_DIR")
            ?? (source == .codex
                ? (nonempty("CODEX_HOME") ?? paths.home + "/.codex") : paths.home + "/.claude")
            + "/notifications/ghostty-sessions"
        guard !directory.contains("\0") else { return }
        if directory.hasPrefix("~/") { directory = paths.home + String(directory.dropFirst()) }
        if !directory.hasPrefix("/") {
            directory = FileManager.default.currentDirectoryPath + "/" + directory
        }
        directory = URL(fileURLWithPath: directory).standardizedFileURL.path
        guard directory != "/" else { return }
        var event = HookEvent(
            source: source,
            roundID: DiskRoundJournal.read(directory + "/" + sessionID + ".round"),
            occurredAt: Date().timeIntervalSince1970, sessionDirectory: directory,
            rateDirectory: directory,
            settings: environment.filter { $0.key.hasPrefix("GHOSTTY_NOTIFY_") },
            payload: HookPayload(sessionID: sessionID, kind: .prompt))
        event.homeDirectory = paths.home
        event.searchPath = environment["PATH"]
        let (binding, external) = dependencies(paths: paths)
        if mode == "--focus" {
            let tab = await binding.existing(event)
            AgentLog.append(
                "native focus: session=\(sessionID) tab=\(tab ?? "<none>")", to: paths.log)
            await MacTerminalAutomation().focus(tabID: tab)
        } else {
            await external.clear(event, force: true)
        }
    }
}
