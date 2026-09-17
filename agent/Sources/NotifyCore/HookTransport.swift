import Darwin
import Foundation

/// One atomic publication rule for --send, hooks and native fallback workers.
public enum AtomicSpool {
    public static func prepareDirectory(_ directory: String) throws {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // createDirectory does not change permissions on an older installation.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    }

    public static func write(_ data: Data, to directory: String) throws {
        guard !data.isEmpty else { throw RequestDecodeError.missingField("request") }
        try prepareDirectory(directory)
        let name =
            String(format: "%016ld-", Int(Date().timeIntervalSince1970 * 1000))
            + UUID().uuidString + ".json"
        let temporary = URL(fileURLWithPath: directory).appendingPathComponent("." + name + ".tmp")
        let final = URL(fileURLWithPath: directory).appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Keep prompt/settings payloads private from the first byte, not only
        // after writing. O_EXCL also rejects a preexisting file or symlink.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        try output.write(contentsOf: data)
        try output.close()
        try FileManager.default.moveItem(at: temporary, to: final)
    }
}

public struct HookTransport: Sendable {
    public var paths: AgentPaths
    private let inspector: any ProcessInspecting
    public init(paths: AgentPaths, inspector: any ProcessInspecting = MacProcessInspector()) {
        self.paths = paths
        self.inspector = inspector
    }
    public var runningPID: Int32? {
        guard let pid = Int32(DiskRoundJournal.read(paths.pidFile)), pid > 1,
            let process = inspector.process(pid),
            URL(fileURLWithPath: process.executable).lastPathComponent == "ghostty-notify-agent"
        else { return nil }
        // The same binary also has short-lived modes. A reused hook/worker PID
        // is not evidence of a running spool consumer.
        let arguments = inspector.arguments(pid)
        guard !arguments.isEmpty, arguments.dropFirst().allSatisfy({ !$0.hasPrefix("--") }) else {
            return nil
        }
        return pid
    }
    public var authorized: Bool {
        runningPID != nil
            && DiskRoundJournal.read(paths.readyFile) == AgentConstants.readyAuthorized
    }
    public var acceptsHookEvents: Bool {
        guard let pid = runningPID else { return false }
        return DiskRoundJournal.read(paths.root + "/capabilities")
            .split(whereSeparator: \.isNewline).contains("hook-event-v1:\(pid)")
    }
    public var acceptsNativeHooks: Bool {
        guard let pid = runningPID else { return false }
        return acceptsHookEvents
            && DiskRoundJournal.read(paths.root + "/native-hook-ready") == "native-hook-v1:\(pid)"
    }
    public func queue(_ request: AgentRequest) throws {
        try AtomicSpool.write(RequestCodec.encode(request), to: paths.spool)
    }
    public static func application(event: HookEvent, home: String) -> String? {
        let suffix = "/Contents/MacOS/ghostty-notify-agent"
        if let override = event.settings["GHOSTTY_NOTIFY_AGENT_APP"] {
            return !override.isEmpty
                && FileManager.default.isExecutableFile(atPath: override + suffix)
                ? override : nil
        }
        let candidates = [
            home + "/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app",
            event.hooksDirectory + "/../build/ClaudeGhosttyNotify.app",
            event.hooksDirectory + "/ClaudeGhosttyNotify.app",
            home + "/.claude/hooks/ClaudeGhosttyNotify.app",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0 + suffix) }
    }
}
