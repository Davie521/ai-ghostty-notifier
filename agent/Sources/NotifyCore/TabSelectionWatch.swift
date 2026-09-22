/// Turns polls of Ghostty's selected tab into tab switches.
///
/// Moving between Ghostty's tabs activates no app, so the activation observer
/// never hears of it, and a notification waiting on the tab the user just
/// opened stayed up until a prompt, a click or its timeout. Polling the
/// selection closes that gap, but a poll says where the user *is*, not where
/// they went, so the first answer is only a baseline. Counting it as a switch
/// would withdraw a notification posted onto the tab the user is already
/// watching about a second later, cutting short the grace the agent gives
/// exactly that case.
public struct TabSelectionWatch: Equatable, Sendable {
    public private(set) var lastSeen: String?

    public init() {}

    /// The tab the user moved to since the previous answer, or nil for none.
    /// A failed query is "don't know": it neither reports a switch nor
    /// forgets the baseline.
    public mutating func observe(_ selected: String?) -> String? {
        guard let selected else { return nil }
        defer { lastSeen = selected }
        guard let previous = lastSeen else { return nil }
        return previous == selected ? nil : selected
    }

    /// Ghostty left the front: whatever was selected before is no baseline for
    /// the next time it comes back.
    public mutating func reset() {
        lastSeen = nil
    }
}
