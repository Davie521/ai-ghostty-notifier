import Foundation

/// Owns admission markers separately from the PID used for singleton exclusion.
/// Closing admission is irreversible, including for a late permission callback.
@MainActor
public final class ResidentReadiness {
    private let paths: AgentPaths
    private var accepting = true

    public init(paths: AgentPaths) { self.paths = paths }

    public func publishCapabilities(pid: Int32) throws {
        guard accepting else { return }
        try "hook-event-v1:\(pid)\n".write(
            toFile: paths.root + "/capabilities", atomically: true, encoding: .utf8)
        try "native-hook-v1:\(pid)\n".write(
            toFile: paths.root + "/native-hook-ready", atomically: true, encoding: .utf8)
    }

    public func publishAuthorization(_ value: String) throws {
        guard accepting else { return }
        try (value + "\n").write(toFile: paths.readyFile, atomically: true, encoding: .utf8)
    }

    public func close() {
        accepting = false
        for path in [
            paths.readyFile, paths.root + "/capabilities", paths.root + "/native-hook-ready",
        ] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
