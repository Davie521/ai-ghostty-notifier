import Foundation

/// The notification-authorization answer, as the menu bar needs to read it.
///
/// Three-valued on purpose, mirroring `Notifier.AuthorizationAnswer`: "the user
/// said no" and "the system never asked" look identical in a Bool and have
/// opposite fixes — one is permanent for this bundle identifier, the other
/// clears on a relaunch. The extra `unknown` case is why this is not simply
/// that type: before the answer arrives there is no answer to describe.
public enum NotificationPermission: Equatable, Sendable {
    /// The answer has not come back yet. Treated as working, not as broken: the
    /// first seconds after launch must not flash a failure icon.
    case unknown
    case granted
    case denied
    case unavailable

    /// What a later look at the system's settings makes of the answer. The
    /// user can change it in System Settings while the agent runs, and the
    /// menu's own link sends them there. `authorized` is nil while macOS has
    /// nothing on record, which says no more than was known: only the
    /// launch-time request can tell "never asked" from "could not ask".
    public func updated(authorized: Bool?) -> NotificationPermission {
        guard let authorized else { return self }
        return authorized ? .granted : .denied
    }

    /// The value the hooks read to decide whether routing through the agent
    /// would display anything; nil where there is no answer to publish.
    public var readiness: String? {
        switch self {
        case .granted: return AgentConstants.readyAuthorized
        case .denied: return AgentConstants.readyDenied
        case .unknown, .unavailable: return nil
        }
    }
}

/// A reason the agent cannot put anything on screen at all.
///
/// Deliberately excludes the Temporary (banner) alert style. Banner *does*
/// deliver — it just slides away before it can be clicked — and a user may have
/// settled for it. Pinning a permanent warning glyph to the menu bar for a state
/// that never resolves would drown the one signal this icon exists to carry, so
/// banner is reported in the menu (where it is a clickable fix) and not on the
/// icon.
public enum MenuBarProblem: Equatable, Sendable {
    /// The dialog was shown and the user clicked "Don't Allow".
    case notAuthorized
    /// The system refused to process the request; no dialog appeared.
    case authorizationUnavailable
    /// macOS has this app's alerts switched off entirely.
    case alertsOff
}

/// The two marks the menu bar can wear. Kept as a value rather than an image so
/// the state machine stays testable without AppKit; drawing lives in
/// `ClaudeMark`.
public enum MenuBarIcon: Equatable, Sendable {
    /// Claude's radiating mark — the agent is working.
    case mark
    /// The same mark struck through: the agent is running but nothing it posts
    /// will ever appear.
    case markCrossedOut
}

/// What the menu bar item shows, decided from the agent's state.
///
/// Lives here rather than in the AppKit half so every state transition is
/// testable without a status bar, a notification center, or a run loop — the
/// same split the rest of `NotifyCore` keeps.
public enum MenuBarState: Equatable, Sendable {
    /// Running, permitted, nothing waiting.
    case idle
    /// This many sessions have a notification the user has not dealt with.
    case waiting(Int)
    /// Running but unable to display anything. The count rides along so it is
    /// not lost, even though the icon leads with the problem.
    case problem(MenuBarProblem, waiting: Int)

    public static func resolve(
        permission: NotificationPermission, alertStyle: String, waiting: Int
    ) -> MenuBarState {
        switch permission {
        case .denied:
            return .problem(.notAuthorized, waiting: waiting)
        case .unavailable:
            return .problem(.authorizationUnavailable, waiting: waiting)
        case .unknown, .granted:
            break
        }
        if alertStyle == "none" {
            return .problem(.alertsOff, waiting: waiting)
        }
        return waiting > 0 ? .waiting(waiting) : .idle
    }

    /// Which mark to draw. Idle and waiting share it: the count beside the icon
    /// is what says how many, and a second glyph saying the same thing would
    /// only make the identity harder to recognise at a glance.
    public var icon: MenuBarIcon {
        switch self {
        case .idle, .waiting: return .mark
        case .problem: return .markCrossedOut
        }
    }

    /// Shown next to the icon. Empty means "icon only": a status item that
    /// always carries a number would claim menu bar width even while idle.
    public var badgeText: String {
        switch self {
        case .idle: return ""
        case .waiting(let count), .problem(_, let count):
            return count > 0 ? "\(count)" : ""
        }
    }

    /// VoiceOver reads this, and it is the *only* thing VoiceOver reads —
    /// setting it on the status button overrides both the image description and
    /// the visible count. So it has to carry the count too: a label saying
    /// "not allowed" beside a badge reading "2" would tell a VoiceOver user
    /// nothing is waiting while two sessions are.
    public var accessibilityDescription: String {
        switch self {
        case .idle:
            return "Claude notifications: nothing waiting"
        case .waiting(let count):
            return "Claude notifications: " + Self.waitingPhrase(count)
        case .problem(let problem, let count):
            let headline: String
            switch problem {
            case .notAuthorized: headline = "Claude notifications are not allowed"
            case .authorizationUnavailable:
                headline = "Claude notifications could not be authorized"
            case .alertsOff: headline = "Claude alerts are turned off"
            }
            return count > 0 ? "\(headline); \(Self.waitingPhrase(count))" : headline
        }
    }

    private static func waitingPhrase(_ count: Int) -> String {
        count == 1 ? "1 session waiting" : "\(count) sessions waiting"
    }
}

/// Which part of the notification a row line came from.
///
/// Carried explicitly rather than inferred from position: empty lines are
/// dropped, so after compaction a body can sit where a subtitle would have been
/// and would otherwise be styled as one.
public enum NotificationLineRole: Equatable, Sendable {
    case title
    case subtitle
    case body
}

public struct NotificationLine: Equatable, Sendable {
    public let role: NotificationLineRole
    public let text: String

    public init(role: NotificationLineRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// One session with a notification still on screen, reduced to what a menu row
/// needs. Built from `SessionState`, so the menu never reaches into bookkeeping.
public struct WaitingSession: Equatable, Sendable {
    public let sessionID: String
    /// The notification's title — the app name, "Claude" or "Codex", as the hook
    /// builds it.
    public let title: String
    /// "<session title> — <project>", the part that tells two sessions apart.
    public let subtitle: String
    /// "Finished after 5m 3s", or whatever text the event carried.
    public let body: String
    /// When the notification was posted, for the age shown in the row.
    public let postedAt: Double

    public init(
        sessionID: String,
        title: String,
        subtitle: String,
        body: String,
        postedAt: Double
    ) {
        self.sessionID = sessionID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.postedAt = postedAt
    }

    /// The row's lines, in the notification's own order: title, subtitle, body.
    ///
    /// Nothing is re-worded, re-ordered or re-composed here. The row stands in
    /// for a notification the user may have missed, so it has to say the same
    /// thing the notification said — a menu that summarised it in its own words
    /// would be a second source of truth, and the one the user could no longer
    /// check against.
    ///
    /// Empty lines are dropped, exactly as macOS drops an empty subtitle rather
    /// than leaving a gap; each survivor keeps its role so the caller styles it
    /// by what it *is*, not by where it ended up.
    public func notificationLines(maxLineLength: Int = 64) -> [NotificationLine] {
        [
            (NotificationLineRole.title, title),
            (NotificationLineRole.subtitle, subtitle),
            (NotificationLineRole.body, body),
        ]
        .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .filter { !$0.1.isEmpty }
        .map { NotificationLine(role: $0.0, text: Self.truncate($0.1, to: maxLineLength)) }
    }

    /// A stand-in for a row with nothing to show, so a session waiting on the
    /// user is never invisible just because an old state file predates the text.
    public var fallbackLabel: String { "Session " + sessionID.prefix(8) }

    /// Relative time in Notification Center's vocabulary — the same phrasing
    /// shown on the notification this row stands in for.
    public func relativeTime(now: Double) -> String {
        let elapsed = max(0, now - postedAt)
        if elapsed < 60 { return "now" }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// Long text is clipped rather than wrapped, the way a notification clips
    /// it — a menu is not the place to reflow someone's session title.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard limit > 1, text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
