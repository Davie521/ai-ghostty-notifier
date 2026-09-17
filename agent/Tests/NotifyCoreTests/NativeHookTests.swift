import Foundation
import Testing

@testable import NotifyCore

private struct ProcessFixture: ProcessInspecting {
    var processes: [Int32: HostProcess] = [:]
    var argv: [Int32: [String]] = [:]
    func process(_ pid: Int32) -> HostProcess? { processes[pid] }
    func arguments(_ pid: Int32) -> [String] { argv[pid] ?? [] }
}

@Suite("Native hook intake and transport")
struct NativeHookTests {
    private func inspector(tty: String? = "/dev/ttys001") -> ProcessFixture {
        ProcessFixture(processes: [
            100: HostProcess(
                pid: 100, parent: 200, name: "ghostty-notify",
                executable: "/native/ghostty-notify-agent", tty: tty, birth: "3.0"),
            200: HostProcess(
                pid: 200, parent: 300, name: "zsh", executable: "/bin/zsh", tty: tty, birth: "2.0"),
            300: HostProcess(
                pid: 300, parent: 1, name: "codex", executable: "/native/codex", tty: tty,
                birth: "1.0"),
        ])
    }
    private func parse(
        _ json: String, source: HookSource = .codex, expected: String? = nil,
        environment: [String: String] = [:], processes: ProcessFixture? = nil
    ) throws -> HookEvent? {
        try HookIntake.parse(
            data: Data(json.utf8), source: source, expectedEvent: expected,
            environment: ["HOME": "/Users/test", "TERM_PROGRAM": "ghostty"].merging(environment) {
                _, b in b
            },
            hooksDirectory: "/missing-fixture", cwd: "/work/project", now: 2000.5,
            processID: 100, inspector: processes ?? inspector())
    }
    @Test func capturesNativeParentAndPreservesSourceTimingFacts() throws {
        let event = try #require(try parse(#"{"session_id":"abc-123","hook_event_name":"Stop"}"#))
        #expect(event.owner == "300:ttys001:1.0")
        #expect(event.tty == "/dev/ttys001")
        #expect(event.occurredAt == 2000.5)
        #expect(event.payload.cwd == "/work/project")
        #expect(event.sessionDirectory == "/Users/test/.codex/notifications/ghostty-sessions")
        #expect(event.key == "codex-abc-123")
    }
    @Test func rejectsDesktopMCPSubagentAndMiswiredEventsBeforeWritingState() throws {
        let input = #"{"session_id":"abc-123","hook_event_name":"Stop"}"#
        #expect(try parse(input, processes: inspector(tty: nil)) == nil)
        #expect(try parse(input, processes: ProcessFixture()) == nil)
        #expect(try parse(input, expected: "UserPromptSubmit") == nil)
        #expect(
            try parse(#"{"session_id":"abc-123","hook_event_name":"Stop","agent_id":"child"}"#)
                == nil)
        #expect(try parse(#"{"session_id":"../bad","hook_event_name":"Stop"}"#) == nil)
        #expect(try parse(input, environment: ["TERM_PROGRAM": "iTerm.app"]) == nil)
        #expect(try parse(#"{"session_id":"abc-123","hook_event_name":"PreToolUse"}"#) == nil)
    }
    @Test func nodeStyleArgvIdentityStillFindsClaude() {
        var processes = inspector()
        processes.processes[300]?.name = "node"
        processes.processes[300]?.executable = "/node/bin/node"
        processes.argv[300] = ["/Users/test/.local/bin/claude", "--version"]
        #expect(
            HookProcessContext.owner(source: .claude, startingAt: 100, inspector: processes)?.pid
                == 300)
    }
    @Test func corruptShapesThrowAndNoNullCanReachPaths() throws {
        for json in ["[]", "null", "{", #"{"session_id":1,"hook_event_name":"Stop"}"#] {
            #expect(throws: (any Error).self) { _ = try parse(json) }
        }
        #expect(try parse(#"{"session_id":"abc\u0000","hook_event_name":"Stop"}"#) == nil)
        #expect(throws: (any Error).self) {
            _ = try parse(
                #"{"session_id":"abc","hook_event_name":"Stop"}"#,
                environment: ["GHOSTTY_NOTIFY_SESSION_DIR": "/bad\0path"])
        }
    }
    @Test func effectiveSettingsPreserveSetEmptyAndJSONValueSemantics() throws {
        let config = Data(
            #"{"GHOSTTY_NOTIFY_AGENT_APP":"/app","GHOSTTY_NOTIFY_ON_PROMPT":true,"GHOSTTY_NOTIFY_MIN_ELAPSED":0,"GHOSTTY_NOTIFY_DROP":null,"PRIVATE":"hidden","GHOSTTY_NOTIFY_BAD":"x\u0000y"}"#
                .utf8)
        let env = try HookIntake.merging(
            config: config, environment: ["GHOSTTY_NOTIFY_AGENT_APP": ""])
        #expect(env["GHOSTTY_NOTIFY_AGENT_APP"] == "")
        #expect(env["GHOSTTY_NOTIFY_ON_PROMPT"] == "true")
        #expect(env["GHOSTTY_NOTIFY_MIN_ELAPSED"] == "0")
        #expect(env["PRIVATE"] == nil)
        #expect(env["GHOSTTY_NOTIFY_BAD"] == nil)
        #expect(!HookOptions(env).onPrompt)
    }
    @Test func pathsExpandAgainstSenderAndPromptIsBoundedByScalars() throws {
        let prompt = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        let json = try JSONSerialization.data(withJSONObject: [
            "session_id": "abc", "prompt": prompt, "hook_event_name": "UserPromptSubmit",
        ])
        let event = try #require(
            try parse(
                String(decoding: json, as: UTF8.self),
                environment: [
                    "CODEX_HOME": "~/custom", "GHOSTTY_NOTIFY_SESSION_DIR": "state",
                    "GHOSTTY_NOTIFY_TTY": "/dev/ttys007",
                ]))
        #expect(event.codexHome == "/Users/test/custom")
        #expect(event.sessionDirectory == "/work/project/state")
        #expect(event.payload.prompt?.unicodeScalars.count == 200)
        #expect(event.tty == "/dev/ttys007")
    }

    @Test func backendPathsResolveBeforeLeavingTheSendersWorkingDirectory() throws {
        let event = try #require(
            try parse(
                #"{"session_id":"abc","hook_event_name":"Stop"}"#,
                environment: [
                    "GHOSTTY_NOTIFY_ALERTER": "bin/alerter",
                    "GHOSTTY_NOTIFY_AGENT_APP": "../Native.app",
                ]))
        #expect(event.settings["GHOSTTY_NOTIFY_ALERTER"] == "/work/project/bin/alerter")
        #expect(event.settings["GHOSTTY_NOTIFY_AGENT_APP"] == "/work/Native.app")
        let disabled = try #require(
            try parse(
                #"{"session_id":"abc","hook_event_name":"Stop"}"#,
                environment: ["GHOSTTY_NOTIFY_AGENT_APP": ""]))
        #expect(disabled.settings["GHOSTTY_NOTIFY_AGENT_APP"] == "")
    }
    @Test func readinessRequiresResidentIdentityPermissionAndMatchingCapabilityPID() throws {
        let sandbox = try HookSandbox()
        let paths = try AgentPaths(env: ["HOME": sandbox.root.path])
        try FileManager.default.createDirectory(
            atPath: paths.root, withIntermediateDirectories: true)
        try "400\n".write(toFile: paths.pidFile, atomically: true, encoding: .utf8)
        try "authorized\n".write(toFile: paths.readyFile, atomically: true, encoding: .utf8)
        try "hook-event-v1:400\n".write(
            toFile: paths.root + "/capabilities", atomically: true, encoding: .utf8)
        var processes = ProcessFixture(processes: [
            400: HostProcess(
                pid: 400, parent: 1,
                name: "ghostty-notify", executable: "/app/ghostty-notify-agent", tty: nil,
                birth: "1")
        ])
        #expect(HookTransport(paths: paths, inspector: processes).runningPID == nil)
        processes.argv[400] = ["/app/ghostty-notify-agent"]
        #expect(HookTransport(paths: paths, inspector: processes).acceptsHookEvents)
        #expect(HookTransport(paths: paths, inspector: processes).authorized)
        processes.argv[400] = ["/app/ghostty-notify-agent", "--worker"]
        #expect(HookTransport(paths: paths, inspector: processes).runningPID == nil)
        processes.argv[400] = ["/app/ghostty-notify-agent"]
        try "denied\n".write(toFile: paths.readyFile, atomically: true, encoding: .utf8)
        #expect(!HookTransport(paths: paths, inspector: processes).authorized)
        try "hook-event-v1:401\n".write(
            toFile: paths.root + "/capabilities", atomically: true, encoding: .utf8)
        #expect(!HookTransport(paths: paths, inspector: processes).acceptsHookEvents)
    }
    @Test func spoolUpgradeMakesAnExistingDirectoryPrivate() throws {
        let sandbox = try HookSandbox()
        let directory = sandbox.root.appendingPathComponent("old-spool")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try AtomicSpool.write(RequestCodec.encode(.ping), to: directory.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        for file in files {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[
                .posixPermissions]
            #expect((mode as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test @MainActor func shutdownRevokesAdmissionAndIgnoresLateAuthorization() throws {
        let sandbox = try HookSandbox()
        let paths = try AgentPaths(env: ["HOME": sandbox.root.path])
        try FileManager.default.createDirectory(
            atPath: paths.root, withIntermediateDirectories: true)
        try "400\n".write(toFile: paths.pidFile, atomically: true, encoding: .utf8)
        let processes = ProcessFixture(
            processes: [
                400: HostProcess(
                    pid: 400, parent: 1, name: "ghostty-notify",
                    executable: "/app/ghostty-notify-agent", tty: nil, birth: "1")
            ],
            argv: [400: ["/app/ghostty-notify-agent"]])
        let transport = HookTransport(paths: paths, inspector: processes)
        let readiness = ResidentReadiness(paths: paths)
        try readiness.publishCapabilities(pid: 400)
        try readiness.publishAuthorization("authorized")
        #expect(transport.acceptsNativeHooks && transport.authorized)
        readiness.close()
        #expect(transport.runningPID == 400)
        #expect(!transport.acceptsNativeHooks && !transport.authorized)
        try readiness.publishAuthorization("authorized")
        try readiness.publishCapabilities(pid: 400)
        #expect(!transport.acceptsNativeHooks && !transport.authorized)
        #expect(!FileManager.default.fileExists(atPath: paths.readyFile))
        #expect(!FileManager.default.fileExists(atPath: paths.root + "/capabilities"))
        #expect(!FileManager.default.fileExists(atPath: paths.root + "/native-hook-ready"))
    }

    @Test func concurrentSpoolWritesNeverCollideOrExposeTemporaryFiles() async throws {
        let sandbox = try HookSandbox()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try AtomicSpool.write(RequestCodec.encode(.ping), to: sandbox.root.path)
                }
            }
            try await group.waitForAll()
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path)
        #expect(names.count == 100)
        for name in names {
            #expect(!name.hasPrefix("."))
            #expect(
                try RequestCodec.decode(Data(contentsOf: sandbox.root.appendingPathComponent(name)))
                    == .ping)
        }
    }
    @Test func realArgumentsExcludeEnvironmentAndChildHasBoundedLifetime() async throws {
        let args = MacProcessInspector().arguments(ProcessInfo.processInfo.processIdentifier)
        #expect(!args.isEmpty)
        #expect(!args.contains { $0.hasPrefix("HOME=") })
        let child = try NativeCommandLauncher().start(executable: "/bin/sleep", arguments: ["30"])
        let result = await child.result(timeout: 0.02)
        #expect(result.status != 0)
        #expect(!child.isRunning)
    }
    @Test func cancellationReapsAChildThatIgnoresSIGTERMEvenWithoutTimeout() async throws {
        // Shell is a test fixture only: exec preserves the ignored disposition
        // while leaving a single directly owned child, not a process subtree.
        let child = try NativeCommandLauncher().start(
            executable: "/bin/bash",
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"])
        let inspector = MacProcessInspector()
        for _ in 0..<1000 {
            if inspector.arguments(child.pid).first == "/bin/sleep" { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(inspector.arguments(child.pid).first == "/bin/sleep")
        let result = Task { await child.result(timeout: nil) }
        result.cancel()
        for _ in 0..<200 {
            if !child.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!child.isRunning)
        // A failing regression must still reap only the fixture it started.
        if child.isRunning { kill(child.pid, SIGKILL) }
        _ = await result.value
    }
    @Test func resumedOwnerInvalidatesResidentBindingEvenAfterRestart() throws {
        var state = SessionState()
        state.captureOwner(sessionID: "codex-abc", owner: "old-process")
        state.anchor(sessionID: "codex-abc", tabID: "old-tab", now: 10)
        state = StateCodec.decode(try StateCodec.encode(state))
        #expect(state.sessions["codex-abc"]?.owner == "old-process")
        state.captureOwner(sessionID: "codex-abc", owner: "old-process")
        #expect(state.sessions["codex-abc"]?.tabID == "old-tab")
        state.captureOwner(sessionID: "codex-abc", owner: "new-process")
        state.anchor(sessionID: "codex-abc", tabID: nil, now: 20)
        #expect(state.sessions["codex-abc"]?.tabID == nil)
        state.anchor(sessionID: "codex-abc", tabID: "new-tab", now: 21)
        #expect(state.sessions["codex-abc"]?.tabID == "new-tab")
        let notice = NotifyRequest(
            sessionID: "abc", title: "Codex", source: .codex, owner: "new-process")
        #expect(try RequestCodec.decode(RequestCodec.encode(.notify(notice))) == .notify(notice))
    }
    @Test(arguments: [HookSource.claude, HookSource.codex])
    func ownerChangeInvalidatesDiskBindingForBothCLIs(_ source: HookSource) async throws {
        let sandbox = try HookSandbox()
        var event = try sandbox.event(source: source)
        event.owner = "first-owner"
        let journal = DiskRoundJournal()
        await journal.prepare(event)
        try sandbox.write("abc-123.json", #"{"tab_id":"old-tab"}"#)
        await journal.prepare(event)
        #expect(FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.json"))
        event.owner = "second-owner"
        await journal.prepare(event)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path + "/abc-123.json"))
        #expect(
            DiskRoundJournal.read(sandbox.root.path + "/abc-123." + source.rawValue + "-owner")
                == "second-owner")
    }
}
