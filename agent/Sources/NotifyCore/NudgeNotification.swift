import Foundation

/// What `ghostty-notify-agent --nudge <message>` asks the resident agent to
/// post, and what it tells the coding agent that ran it.
///
/// Every other notification is posted for the user by a hook, when a run ends.
/// A nudge is the coding agent calling the user itself, part-way through: it
/// needs something only they can give (Face ID, a code, a scan, a decision)
/// and they may have walked away.
///
/// It is posted as the session's own notification, under the session id
/// Claude Code's hooks see, so it behaves like the others: Go to tab returns
/// to the session's tab, the menu bar lists it, and returning to the tab, the
/// next prompt or the timeout withdraws it. One session has one notification,
/// so a nudge replaces what the session had on screen, and the run's own
/// completion notification later replaces the nudge.
public enum NudgeNotification {
    /// Longer than this is cut. macOS shows about four lines in a banner, and
    /// a nudge says one thing.
    public static let maximumLength = 240

    /// The Claude Code session the caller runs in. Claude Code sets this for
    /// every command its Bash tool runs, and it is the id its hooks receive.
    public static func sessionID(environment: [String: String]) -> String? {
        guard let id = environment["CLAUDE_CODE_SESSION_ID"], RequestCodec.isValidSessionID(id)
        else { return nil }
        return id
    }

    /// The message on one line, without control characters and bounded, or
    /// nil when nothing is left to say.
    public static func message(_ words: [String]) -> String? {
        let line = NotificationPolicy.clean(
            words.joined(separator: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " "))
        guard !line.isEmpty else { return nil }
        guard line.count > maximumLength else { return line }
        return String(line.prefix(maximumLength - 1)) + "…"
    }

    /// `title` is the session's title, empty when it has none; `roundID` is the
    /// session's current round, so the next prompt withdraws the nudge with the
    /// rest of that round's notifications.
    ///
    /// No owner: the session already has one, recorded by its hooks, and a
    /// different one would make the agent forget the session's tab.
    public static func request(
        sessionID: String, message: String, title: String, project: String, tabID: String?,
        roundID: String?, settings: [String: String], bundle: Bundle = .main
    ) -> NotifyRequest {
        let options = HookOptions(settings)
        let app =
            settings["GHOSTTY_NOTIFY_APP_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "Claude"
        let name = title.isEmpty ? UIText.text("Needs You", in: bundle) : title
        let subtitle = project.isEmpty ? name : name + " — " + project
        return NotifyRequest(
            sessionID: sessionID, title: app,
            subtitle: NotificationPolicy.clean(subtitle), body: message,
            // Sent because the user is wanted now, so never silent.
            sound: "Ping", tabID: tabID?.isEmpty == false ? tabID : nil,
            timeout: options.timeout, clearOnFocus: options.clearOnFocus,
            roundID: roundID?.isEmpty == false ? roundID : nil, source: .claude)
    }

    public enum Problem: Equatable, Sendable {
        /// Not run by Claude Code, so there is no session to post for.
        case noSession
        /// The agent cannot take it. `.notCollected` means it was queued, not
        /// taken within five seconds, and taken back again.
        case agent(TestNotification.Problem)
        /// Queued, not taken, and could not be taken back: the agent may still
        /// post it later.
        case stuck(String)
    }

    public static func explain(_ problem: Problem, app: String) -> String {
        switch problem {
        case .noSession:
            return """
                CLAUDE_CODE_SESSION_ID is not set, so there is no session to nudge for and \
                nothing was sent.
                --nudge works in commands Claude Code runs; the notification leads back to \
                that session's tab.
                """
        case .agent(.notCollected):
            return """
                The agent did not pick up the nudge within five seconds, so it was taken \
                back and nothing was sent.
                Its log may say why: ~/.claude/notifications/ghostty-agent/agent.log
                """
        case .agent(let problem):
            return TestNotification.explain(problem, app: app, unsent: "nothing was sent")
        case .stuck(let reason):
            return """
                The agent did not pick up the nudge within five seconds, and it could not be \
                taken back (\(reason)), so it may still appear later.
                Its log may say why: ~/.claude/notifications/ghostty-agent/agent.log
                """
        }
    }

    public static let usage = "usage: ghostty-notify-agent --nudge <what you need from the user>"

    public static func sent(tabKnown: Bool) -> String {
        tabKnown
            ? "Sent. Go to tab brings the user back to this session's tab."
            : "Sent, but this session's tab is not known yet, so Go to tab only brings "
                + "Ghostty forward."
    }
}
