import Darwin
import Foundation

/// Bounded child processes for native disk/terminal adapters. An output file
/// avoids pipe-capacity deadlocks; stdin is closed and all jobs are reaped.
public enum ChildCommand {
    public static func output(
        executable: String, arguments: [String],
        environment: [String: String]? = nil, input: Data? = nil,
        timeout: Double = 20
    ) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "ghostty-child-" + UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(
                        at: root, withIntermediateDirectories: false)
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                defer { try? FileManager.default.removeItem(at: root) }
                let out = root.appendingPathComponent("stdout")
                let stdin = root.appendingPathComponent("stdin")
                FileManager.default.createFile(atPath: out.path, contents: nil)
                try? (input ?? Data()).write(to: stdin)
                guard let writer = try? FileHandle(forWritingTo: out),
                    let reader = try? FileHandle(forReadingFrom: stdin)
                else {
                    continuation.resume(returning: "")
                    return
                }
                defer {
                    try? writer.close()
                    try? reader.close()
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                process.standardInput = reader
                process.standardOutput = writer
                process.standardError = FileHandle.nullDevice
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                do { try process.run() } catch {
                    continuation.resume(returning: "")
                    return
                }
                if done.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    if done.wait(timeout: .now() + 1) == .timedOut {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                process.waitUntilExit()
                continuation.resume(
                    returning: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
            }
        }
    }
}
