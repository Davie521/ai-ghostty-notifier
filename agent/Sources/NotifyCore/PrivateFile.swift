import Darwin
import Foundation

/// Session records, notification state and the log carry prompt text, titles
/// and working directories. A home directory is commonly traversable by every
/// local account, so these are private by mode, not by location.
public enum PrivateFile {
    /// Replaces `path` atomically with a file that was 0600 from its first byte.
    public static func write(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            "." + url.lastPathComponent + "." + UUID().uuidString + ".tmp"
        ).path
        // O_EXCL also rejects a preexisting file or symlink at the temporary name.
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try output.write(contentsOf: data)
            try output.close()
            guard rename(temporary, path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    public static func write(_ text: String, to path: String) throws {
        try write(Data(text.utf8), to: path)
    }

    /// 0700 for whatever this call creates. A directory that exists is left as
    /// it is: it may be one the user chose through a setting.
    public static func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// For a directory only this program uses: also closes one that an earlier
    /// version created open. Missing is fine, there is nothing to close.
    public static func closeDirectory(_ path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }
}
