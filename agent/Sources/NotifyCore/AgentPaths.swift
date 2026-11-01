import Foundation

public enum AgentConstants {
    /// The name the user sees: in notification banners, System Settings, the
    /// menu and the setup window. Must match CFBundleName in Info.plist, which
    /// is what macOS itself shows; a test holds the two together. The project's
    /// name, not Claude's — the app serves Codex CLI too. Only the name: the
    /// bundle identifier, which the permission grants are keyed to, stays.
    public static let displayName = "AI Ghostty Notifier"
    public static let ghosttyBundleID = "com.mitchellh.ghostty"
    /// Category carrying the "Go to tab" button. Registered at launch; every
    /// posted notification references it.
    public static let categoryID = "com.ghostty-notify.session"
    public static let gotoActionID = "goto-tab"
    /// Sessions untouched for this long are forgotten and their leftover
    /// notifications withdrawn.
    public static let sessionMaxAge: Double = 86_400
    /// Requests older than this are dropped instead of replayed. Without it, an
    /// agent that was down all evening posts the whole backlog at once on the
    /// next login — a burst of banners for rounds that finished hours ago.
    /// Dismiss and anchor requests are exempt: replaying them late is harmless
    /// and still useful.
    public static let staleNotifyAge: Double = 300
    /// Written by the agent once the notification authorization answer is
    /// known. The hooks read it to decide whether routing through the agent
    /// would actually display anything; they match only `readyAuthorized`, so
    /// every other value selects the native external-backend fallback.
    public static let readyAuthorized = "authorized"
    /// The dialog was shown and the user clicked "Don't Allow" — permanent for
    /// this bundle identifier.
    public static let readyDenied = "denied"
    /// The system refused to process the request: no dialog appeared and no
    /// answer was recorded. Seen on a bundle's first contact with the
    /// notification system, before its registration has settled — a later
    /// launch can succeed, so this must never be reported as the user's answer.
    public static let readyError = "error"
}

public enum AgentPathsError: Error, Equatable {
    case missingHome
}

/// Every path the agent touches, derived from HOME so the integration test can
/// point the whole agent at a sandbox.
public struct AgentPaths: Equatable, Sendable {
    public let home: String

    /// `GHOSTTY_NOTIFY_NUDGE_SPOOL`, an absolute path, moves `nudgeSpool`; only
    /// the integration test sets it.
    private let nudgeSpoolOverride: String?
    /// TMPDIR, for when macOS will not name the user's temporary directory.
    private let temporaryOverride: String?

    public init(env: [String: String]) throws {
        guard let home = env["HOME"], !home.isEmpty else {
            throw AgentPathsError.missingHome
        }
        self.home = home
        nudgeSpoolOverride = env["GHOSTTY_NOTIFY_NUDGE_SPOOL"].flatMap {
            $0.hasPrefix("/") && $0 != "/" && !$0.contains("\0") ? $0 : nil
        }
        temporaryOverride = env["TMPDIR"]
    }

    public var root: String { home + "/.claude/notifications/ghostty-agent" }
    /// Requests land here as one JSON file each, made visible by rename.
    public var spool: String { root + "/spool" }
    /// Where `--nudge` puts its notification when it may not write `spool`:
    /// Codex CLI's sandbox refuses every write under ~/.claude, but leaves the
    /// user's own temporary directory writable, and that is the agent's too.
    /// The agent takes only notifications from here. Keyed by HOME, so a test
    /// agent with a sandboxed HOME never shares it with the user's. Nil when
    /// macOS names no temporary directory.
    public var nudgeSpool: String? {
        if let nudgeSpoolOverride { return nudgeSpoolOverride }
        guard
            let temporary = Self.temporaryDirectory(
                named: Self.userTemporaryDirectory(), orTMPDIR: temporaryOverride)
        else { return nil }
        return temporary + "io.github.davie521.cgnotify-" + Self.digest(home) + "/nudges"
    }
    /// The agent writes the `nudgeSpool` it watches here. A sandbox may keep
    /// a CLI from asking macOS for the temporary directory (Codex's read-only
    /// one does), and reading a file under ~/.claude it still allows.
    public var nudgeSpoolFile: String { root + "/nudge-spool" }

    /// The per-user directory under /var/folders, the same for every process
    /// of the user whatever TMPDIR says, the agent under launchd included.
    static func userTemporaryDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `named` when macOS named one, else TMPDIR, which for the user's own
    /// processes is the same directory; with a trailing slash. Nil when
    /// neither is an absolute path.
    static func temporaryDirectory(named: String?, orTMPDIR tmpdir: String?) -> String? {
        for candidate in [named, tmpdir] {
            guard let path = candidate, path.hasPrefix("/"), path != "/", !path.contains("\0")
            else { continue }
            return path.hasSuffix("/") ? path : path + "/"
        }
        return nil
    }

    /// FNV-1a, 64 bits: stable across processes and releases, unlike Hasher.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
    /// Session bookkeeping, so a restart does not orphan live notifications.
    public var state: String { root + "/state.json" }
    /// Written on launch, removed on exit; lets hooks tell "agent is up" from
    /// "agent needs launching" without spawning anything.
    public var pidFile: String { root + "/agent.pid" }
    /// Holds `authorized` or `denied`. A hook that finds anything else must
    /// assume the agent cannot display a notification and use a native worker.
    public var readyFile: String { root + "/ready" }
    /// Holds `banner`, `alert` or `none` — the notification style macOS has
    /// recorded for this app. An app cannot set it (Apple removed that), so the
    /// install script reads this to decide whether to send the user to System
    /// Settings, where it is the difference between a notification you can click
    /// and one that slides away before you can.
    public var alertStyleFile: String { root + "/alert-style" }
    /// Written once the style guidance has been shown, so a background agent
    /// that restarts at every login does not put a dialog in the user's face
    /// again and again.
    public var styleHintShownFile: String { root + "/style-hint-shown" }
    /// Written once macOS has been asked for the Accessibility permission,
    /// so the ask is made once per install, not once per launch.
    public var accessibilityAskedFile: String { root + "/accessibility-asked" }
    public var log: String { root + "/agent.log" }
    /// The default locations of everything this program keeps, for both CLIs.
    /// Only the defaults: a directory chosen through a setting is the user's.
    public func ownedDirectories(codexHome: String?) -> [String] {
        let codex = codexHome.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home + "/.codex"
        return [root]
            + [home + "/.claude", codex].flatMap { base in
                [base + "/notifications/ghostty-sessions", base + "/notifications/state"]
            }
    }
    /// Where ghostty-tab-save.sh records each session's resolved tab id.
    public func sessionTabFile(sessionID: String) -> String {
        home + "/.claude/notifications/ghostty-sessions/" + sessionID + ".json"
    }
}

/// JSON round-trip for `SessionState`, kept beside the paths because both
/// halves of persistence want to stay testable without a filesystem.
public enum StateCodec {
    private struct Wire: Codable {
        struct Record: Codable {
            var tabID: String?
            var notificationIDs: [String]
            var clearOnFocus: Bool?
            var updatedAt: Double
            /// Optional so state written by an older agent still decodes. A
            /// required field here would make one upgrade throw away every
            /// session's resolved tab id, which is what click-to-jump runs on.
            var title: String?
            var subtitle: String?
            var body: String?
            var postedAt: Double?
            var roundID: String?
            var owner: String?
            var expiresAt: Double?
        }
        var sessions: [String: Record]
    }

    public static func encode(_ state: SessionState) throws -> Data {
        let wire = Wire(
            sessions: state.sessions.mapValues {
                Wire.Record(
                    tabID: $0.tabID,
                    notificationIDs: $0.notificationIDs,
                    clearOnFocus: $0.clearOnFocus,
                    updatedAt: $0.updatedAt,
                    title: $0.title,
                    subtitle: $0.subtitle,
                    body: $0.body,
                    postedAt: $0.postedAt,
                    roundID: $0.roundID, owner: $0.owner, expiresAt: $0.expiresAt)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(wire)
    }

    /// Corrupt or truncated state is not worth recovering — the agent starts
    /// clean rather than acting on half-decoded bookkeeping.
    public static func decode(_ data: Data) -> SessionState {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return SessionState()
        }
        var state = SessionState()
        state.restore(
            sessions: wire.sessions.mapValues {
                SessionRecord(
                    tabID: $0.tabID,
                    notificationIDs: $0.notificationIDs,
                    // State written before this field existed predates the
                    // opt-out, so the documented default applies.
                    clearOnFocus: $0.clearOnFocus ?? true,
                    updatedAt: $0.updatedAt,
                    title: $0.title ?? "",
                    subtitle: $0.subtitle ?? "",
                    body: $0.body ?? "",
                    // State written before this field existed has no posted
                    // time. Backfilled once, here, rather than resolved on
                    // every read: an anchor moves `updatedAt`, so a read-time
                    // fallback would make an hours-old notification start
                    // reporting itself as "now" the moment the next prompt is
                    // submitted — the exact bug `postedAt` exists to prevent.
                    postedAt: $0.postedAt ?? $0.updatedAt,
                    roundID: $0.roundID, owner: $0.owner, expiresAt: $0.expiresAt)
            }
        )
        return state
    }
}

extension SessionState {
    /// Rehydrate from persisted bookkeeping.
    ///
    /// One assignment, not a replay through the mutating API: rebuilding each
    /// record field by field meant every new `SessionRecord` field needed its
    /// own setter, and a field whose setter was forgotten decoded correctly and
    /// was then silently thrown away here.
    mutating func restore(sessions: [String: SessionRecord]) {
        self.sessions = sessions
    }
}
