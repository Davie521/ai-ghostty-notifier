import Darwin
import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

public protocol RunningCommand: Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func result(timeout: Double?) async -> CommandResult
    func cancel()
}
public protocol CommandLaunching: Sendable {
    func start(executable: String, arguments: [String]) throws -> any RunningCommand
}

/// Direct argv only. No shell interpretation, no open stdin, no output-pipe
/// capacity deadlock. A child is always reaped, including timeout/cancellation.
public struct NativeCommandLauncher: CommandLaunching {
    public init() {}
    public func start(executable: String, arguments: [String]) throws -> any RunningCommand {
        try NativeRunningCommand(executable: executable, arguments: arguments)
    }
}

private final class NativeRunningCommand: RunningCommand, @unchecked Sendable {
    private let process = Process()
    private let root: URL
    private let output: URL
    private let writer: FileHandle
    private let signal = DispatchSemaphore(value: 0)
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    init(executable: String, arguments: [String]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ghostty-command-" + UUID().uuidString)
        output = root.appendingPathComponent("stdout")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(
            atPath: output.path, contents: nil,
            attributes: [.posixPermissions: 0o600])
        do { writer = try FileHandle(forWritingTo: output) } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = writer
        process.standardError = writer
        let signal = self.signal
        process.terminationHandler = { _ in signal.signal() }
        do { try process.run() } catch {
            try? writer.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    func cancel() {
        let firstCancellation = cancellationLock.withLock {
            guard !cancellationRequested else { return false }
            cancellationRequested = true
            return true
        }
        guard firstCancellation, process.isRunning else { return }
        process.terminate()
        // Cancellation has its own deadline, even when the user configured an
        // indefinite notification timeout. Retain this directly owned child
        // until it exits or the escalation runs; never signal an arbitrary PID.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    func result(timeout: Double?) async -> CommandResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    let deadline =
                        timeout.map { DispatchTime.now() + max(0.1, $0) } ?? .distantFuture
                    if signal.wait(timeout: deadline) == .timedOut {
                        cancel()
                        if signal.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                    process.waitUntilExit()
                    try? writer.close()
                    // Help/action output is small; don't retain arbitrary output
                    // from a malfunctioning optional backend in the resident app.
                    let data =
                        (try? FileHandle(forReadingFrom: output)).map { handle in
                            defer { try? handle.close() }
                            return (try? handle.read(upToCount: 262144)) ?? Data()
                        } ?? Data()
                    continuation.resume(
                        returning: CommandResult(
                            status: process.terminationStatus,
                            output: String(decoding: data, as: UTF8.self)))
                }
            }
        } onCancel: {
            self.cancel()
        }
    }
    deinit {
        if process.isRunning { process.terminate() }
        try? writer.close()
        try? FileManager.default.removeItem(at: root)
    }
}

public enum ExecutableSearch {
    public static func find(_ name: String, event: HookEvent) -> String? {
        let home = event.homeDirectory ?? ProcessInfo.processInfo.environment["HOME"] ?? ""
        let path =
            event.searchPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let candidates =
            path.split(separator: ":").map { String($0) + "/" + name }
            + ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name, home + "/.local/bin/" + name]
        return candidates.first {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}
