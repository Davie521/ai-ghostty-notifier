/// Turns polls of Ghostty's selected tab into arrivals at a session's tab.
///
/// Moving between Ghostty's tabs activates no app, so the activation observer
/// never hears of it, and a notification waiting on the tab the user just
/// opened stayed up until a prompt, a click or its timeout. Polling the
/// selection closes that gap, but a poll says where the user *is*, not where
/// they went: being on a session's tab only counts once they were seen
/// somewhere else while its notification was up.
///
/// That is judged per notification, not against one baseline for all of them.
/// A single baseline cannot tell whether the user reached a tab before or
/// after its notification was posted: set when the poll starts, it misses a
/// switch made between posting and the first answer, and the notification
/// then stays for as long as the user stays; kept from an earlier poll, it
/// reads an arrival that preceded the notification as a new one and cuts
/// short the grace the agent gives a notification posted onto the tab the
/// user is already watching.
public struct TabSelectionWatch: Equatable, Sendable {
    public enum Seen: Equatable, Sendable {
        /// Ghostty was not in front, so any tab it shows next is an arrival.
        case outside
        case tab(String)
    }

    /// Per session: the selection last seen while its notification was up.
    /// Missing means not known yet, and the next answer is only a baseline.
    public private(set) var seen: [String: Seen] = [:]

    public init() {}

    /// A notification was just posted. `selected` is where the user was at
    /// that moment, or nil while that is still being asked. It replaces
    /// whatever the session's previous notification had seen.
    public mutating func posted(sessionID: String, selected: Seen?) {
        seen[sessionID] = selected
    }

    /// The post-time answer arrived. A poll that answered first already
    /// described the same moment, so it is kept.
    public mutating func postedSelectionKnown(sessionID: String, selected: String) {
        if seen[sessionID] == nil { seen[sessionID] = .tab(selected) }
    }

    /// Another app came forward: whichever tab Ghostty shows next, the user
    /// arrives there from outside.
    public mutating func leftGhostty() {
        for sessionID in seen.keys { seen[sessionID] = .outside }
    }

    /// Record a poll of the selection and return the sessions whose tab the
    /// user has just arrived at. `waiting` maps each session a switch could
    /// clear to its tab. A failed query is "don't know": it reports nothing
    /// and forgets nothing.
    public mutating func observe(_ selected: String?, waiting: [String: String]) -> [String] {
        guard let selected else { return [] }
        seen = seen.filter { waiting[$0.key] != nil }
        var arrived: [String] = []
        for (sessionID, tabID) in waiting {
            let before = seen[sessionID]
            seen[sessionID] = .tab(selected)
            guard let before else { continue }
            if tabID == selected, before != .tab(selected) { arrived.append(sessionID) }
        }
        return arrived.sorted()
    }
}
