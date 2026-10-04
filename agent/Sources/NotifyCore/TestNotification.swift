import Foundation

/// What `ghostty-notify-agent --test` asks the resident agent to post, and what
/// it tells the person who ran it.
///
/// A fresh install has no other way to show that it works. A task under the
/// minimum duration never notifies, by design, so the quick prompt people send
/// to try an install gets nothing back and reads as broken (issue #48).
public enum TestNotification {
    /// One fixed session, so a second test replaces the first instead of
    /// adding another row to the menu bar.
    public static let sessionID = "00000000-0000-0000-0000-000000007e57"
    /// Long enough to switch away and try Go to tab; then it withdraws itself.
    public static let timeout: Double = 120

    public static func request(tabID: String?, bundle: Bundle = .main) -> NotifyRequest {
        NotifyRequest(
            sessionID: sessionID,
            title: AgentConstants.displayName,
            subtitle: UIText.text("Test notification", in: bundle),
            body: UIText.text(
                "Tasks that run 3 minutes or longer notify you like this.", in: bundle),
            sound: "Glass",
            tabID: tabID,
            timeout: timeout,
            // Posted while its own tab is in front, which is where it is run
            // from, a clearing one would be withdrawn three seconds later,
            // before anyone could try its button.
            clearOnFocus: false)
    }

    public enum Problem: Equatable, Sendable {
        case notRunning
        /// The answer the agent recorded for notification permission; empty
        /// when there is none yet.
        case notAuthorized(String)
        /// Queued, but the agent did not take it from the spool.
        case notCollected
    }

    /// Why a test cannot be sent now, or nil when it can.
    public static func problem(running: Bool, readiness: String) -> Problem? {
        guard running else { return .notRunning }
        guard readiness == AgentConstants.readyAuthorized else {
            return .notAuthorized(readiness)
        }
        return nil
    }

    public static func explain(_ problem: Problem, app: String) -> String {
        switch problem {
        case .notRunning:
            return """
                The agent is not running, so no test was sent. Start it with:
                  open "\(app)"
                or run the installer again.
                """
        case .notAuthorized(AgentConstants.readyDenied):
            return """
                macOS does not allow \(AgentConstants.displayName) to show notifications, \
                so no test was sent.
                Turn them on in System Settings → Notifications → \(AgentConstants.displayName).
                """
        case .notAuthorized(let answer):
            let state = answer.isEmpty ? "no answer yet" : answer
            return """
                \(AgentConstants.displayName) has no notification permission (\(state)), \
                so no test was sent.
                Run the installer again and click Allow when macOS asks.
                """
        case .notCollected:
            return """
                The test was queued, but the agent did not pick it up within five seconds.
                Its log may say why: ~/.claude/notifications/ghostty-agent/agent.log
                """
        }
    }

    public static func sent(toTab: Bool) -> String {
        let target =
            toTab
            ? "Go to tab brings back the tab you ran this from."
            : "Ghostty was not in front, so Go to tab only brings Ghostty forward."
        return """
            Sent a test notification. \(target)
            It withdraws itself after two minutes.
            Nothing on screen? Check Focus modes and System Settings → Notifications → \
            \(AgentConstants.displayName).
            """
    }
}
