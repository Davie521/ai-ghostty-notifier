import Darwin
import Foundation

public struct HostProcess: Equatable, Sendable {
    public var pid: pid_t
    public var parent: pid_t
    public var name: String
    public var executable: String
    public var tty: String?
    public var birth: String
    public init(
        pid: pid_t, parent: pid_t, name: String, executable: String,
        tty: String?, birth: String
    ) {
        self.pid = pid
        self.parent = parent
        self.name = name
        self.executable = executable
        self.tty = tty
        self.birth = birth
    }
    public var owner: String {
        "\(pid):\(tty.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-"):\(birth)"
    }
}

public protocol ProcessInspecting: Sendable {
    func process(_ pid: pid_t) -> HostProcess?
    func arguments(_ pid: pid_t) -> [String]
}

public protocol ProcessSignalling: Sendable {
    func terminate(_ pid: pid_t)
}
public struct MacProcessSignaller: ProcessSignalling {
    public init() {}
    public func terminate(_ pid: pid_t) { _ = kill(pid, SIGTERM) }
}

extension ProcessInspecting {
    public func arguments(_ pid: pid_t) -> [String] { [] }
}

public struct MacProcessInspector: ProcessInspecting {
    public init() {}
    public func arguments(_ pid: pid_t) -> [String] {
        guard pid > 0 else { return [] }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
            size > MemoryLayout<Int32>.size, size <= 4 * 1024 * 1024
        else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65536 else { return [] }
        var index = MemoryLayout<Int32>.size
        // Skip executable path and its alignment padding. Never return the
        // environment that follows argv (it can contain secrets).
        while index < size, bytes[index] != 0 { index += 1 }
        while index < size, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            guard index < size else { return [] }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
    public func process(_ pid: pid_t) -> HostProcess? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro (4 * MAXPATHLEN)
        // and is not imported by Swift.
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        let executable =
            length > 0 ? String(decoding: path.prefix(while: { $0 != 0 }), as: UTF8.self) : ""
        let name = withUnsafeBytes(of: &info.pbi_name) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        var ttyBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let tty: String?
        if info.e_tdev != UInt32.max,
            devname_r(
                dev_t(bitPattern: info.e_tdev), mode_t(S_IFCHR), &ttyBuffer, Int32(ttyBuffer.count))
                != nil
        {
            tty =
                "/dev/"
                + String(
                    decoding: ttyBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                    as: UTF8.self)
        } else {
            tty = nil
        }
        return HostProcess(
            pid: pid, parent: pid_t(info.pbi_ppid), name: name,
            executable: executable, tty: tty,
            birth: "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)")
    }
}

public enum HookProcessContext {
    /// Resolve while this process is still a child of the originating CLI.
    public static func owner(
        source: HookSource, startingAt pid: pid_t = getpid(),
        inspector: any ProcessInspecting = MacProcessInspector()
    ) -> HostProcess? {
        var current = pid
        var visited = Set<pid_t>()
        for _ in 0..<24 {
            guard current > 1, visited.insert(current).inserted,
                let process = inspector.process(current)
            else { return nil }
            let executableName = URL(fileURLWithPath: process.executable).lastPathComponent
            let argumentName = inspector.arguments(current).first.map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
            if process.name == source.rawValue || executableName == source.rawValue
                || argumentName == source.rawValue
            {
                return process.tty == nil ? nil : process
            }
            current = process.parent
        }
        return nil
    }
}
