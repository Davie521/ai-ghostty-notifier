import Foundation

/// Append-only log, deliberately outside any actor: the notification center
/// calls back on threads it does not name, and a log line must never be the
/// reason a callback has to hop.
enum AgentLog {
    /// Keeps the file from growing without bound across weeks of uptime.
    private static let maxBytes = 1 << 20

    static func append(_ message: String, to path: String) {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let line = "\(stamp()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            try? data.write(to: URL(fileURLWithPath: path))
            return
        }
        defer { try? handle.close() }
        let end = handle.seekToEndOfFile()
        if end > UInt64(maxBytes) {
            try? handle.truncate(atOffset: 0)
        }
        handle.write(data)
    }

    private static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }
}
