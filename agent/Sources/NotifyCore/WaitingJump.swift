import Foundation

/// What `--jump-waiting` answers before it asks the agent to move.
///
/// The command exists for a keyboard shortcut or a foot pedal: one press goes
/// where a click on the newest notification would. Its exit status is the
/// point of deciding this up front — a caller that gets "nothing is waiting"
/// can fall back to something of its own, such as the next tab, instead of a
/// press that silently does nothing.
///
/// The decision reads the agent's saved bookkeeping, so it can be a moment
/// old. The agent decides again when the request arrives; this only has to be
/// right about whether to bother asking.
public enum WaitingJump {
    public enum Plan: Equatable, Sendable {
        /// No agent to ask. Nothing moves.
        case notRunning
        /// The agent is up, but no notification is waiting for the user.
        case nothingWaiting
        /// Ask the agent to go to this session, the one with the newest notification.
        case jump(sessionID: String)
    }

    public static func plan(residentRunning: Bool, savedState: Data?) -> Plan {
        guard residentRunning else { return .notRunning }
        guard let savedState,
            let newest = StateCodec.decode(savedState).waitingSessions().first
        else { return .nothingWaiting }
        return .jump(sessionID: newest.sessionID)
    }
}
