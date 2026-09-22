import Foundation

/// What the agent remembers about one Claude session.
public struct SessionRecord: Equatable, Sendable {
    public var roundID: String?
    public var owner: String?
    /// Ghostty tab id this session lives in, or nil when it could never be
    /// resolved — tmux, a session started while Ghostty was in the background,
    /// or AppleScript being unavailable.
    public var tabID: String?
    /// Identifiers of notifications posted for this session and not yet
    /// withdrawn. At most one in practice, because the identifier is stable per
    /// session so a new notification replaces the previous one.
    public var notificationIDs: [String]
    /// False when the notification was posted with
    /// GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0: focus must never withdraw it.
    public var clearOnFocus: Bool
    public var updatedAt: Double
    /// What the outstanding notification says, kept so the menu bar can name the
    /// session instead of counting anonymous ones. The hook already sends all
    /// three on every notify; before this they were handed to the notification
    /// center and forgotten, which left "3 notifications waiting" as the most
    /// the agent could say about work the user had to choose between.
    public var title: String
    public var subtitle: String
    public var body: String
    /// When the outstanding notification was posted. Separate from `updatedAt`,
    /// which an anchor moves without anything new being on screen.
    public var postedAt: Double
    /// When the outstanding notification is due to be withdrawn, or nil when it
    /// stays until focus, a prompt or a click. Kept here, and so on disk, since
    /// a timer alone dies with the process: an agent restarted by an upgrade or
    /// a login left every surviving notification without its timeout.
    public var expiresAt: Double?

    public init(
        tabID: String? = nil,
        notificationIDs: [String] = [],
        clearOnFocus: Bool = true,
        updatedAt: Double = 0,
        title: String = "",
        subtitle: String = "",
        body: String = "",
        postedAt: Double = 0,
        roundID: String? = nil,
        owner: String? = nil,
        expiresAt: Double? = nil
    ) {
        self.tabID = tabID
        self.notificationIDs = notificationIDs
        self.clearOnFocus = clearOnFocus
        self.updatedAt = updatedAt
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.postedAt = postedAt
        self.roundID = roundID
        self.owner = owner
        self.expiresAt = expiresAt
    }

    /// Drop the notification's text once nothing is on screen for this session.
    ///
    /// The record outlives the notification by up to `sessionMaxAge` so its
    /// resolved tab survives, and the text is the user's session title, their
    /// project folder and whatever Claude was asking — none of which reached
    /// disk at all before the menu needed it. Keeping it for a day after the
    /// notification is gone buys nothing, since no reader looks at it once
    /// `notificationIDs` is empty.
    mutating func clearNotice() {
        roundID = nil
        title = ""
        subtitle = ""
        body = ""
        postedAt = 0
        expiresAt = nil
    }
}

/// Which app just came to the front, and — when it was Ghostty — which tab the
/// user landed on.
public enum FocusEvent: Equatable, Sendable {
    /// Ghostty became frontmost. `selectedTabID` is the selected tab of the
    /// front window, or nil when the Apple Event query failed or Ghostty is not
    /// scriptable.
    case ghosttyActivated(selectedTabID: String?)
    /// The user moved to this tab while Ghostty stayed frontmost. No app came
    /// forward, so macOS reported nothing; only a poll of the selection sees it.
    case ghosttyTabSelected(tabID: String)
    case otherAppActivated
}

/// All session bookkeeping, kept pure so every dismissal rule is testable
/// without a notification center, a run loop, or a live Ghostty.
public struct SessionState: Equatable, Sendable {
    /// Writable inside the module so persistence can rehydrate the whole map in
    /// one assignment. Rebuilding it field by field through a setter per field
    /// meant every new `SessionRecord` field needed a matching mutator, and a
    /// forgotten one was dropped on restart with nothing to catch it.
    public internal(set) var sessions: [String: SessionRecord] = [:]

    public init() {}

    /// One stable identifier per session, which is what gives the shell path's
    /// `-group ghostty-notify-<session>` semantics: re-adding a request with an
    /// identifier that is already delivered *replaces* it, so a session that
    /// stops repeatedly leaves one notification rather than a stack.
    public static func notificationID(sessionID: String) -> String {
        sessionID.hasPrefix("codex-") ? sessionID : "claude-\(sessionID)"
    }

    /// Point a session at a tab. Passing nil records the session without a tab
    /// rather than clearing a previously resolved one — a failed query must not
    /// downgrade good state.
    public mutating func anchor(sessionID: String, tabID: String?, now: Double) {
        var record = sessions[sessionID] ?? SessionRecord()
        if let tabID, !tabID.isEmpty { record.tabID = tabID }
        record.updatedAt = now
        sessions[sessionID] = record
    }

    /// A resumed CLI in another terminal invalidates BOTH the disk binding and
    /// the resident cache. Otherwise a failed new lookup keeps the old tab even
    /// though the journal correctly deleted its JSON file.
    public mutating func captureOwner(sessionID: String, owner: String?) {
        guard let owner, !owner.isEmpty else { return }
        var record = sessions[sessionID] ?? SessionRecord()
        if record.owner != owner { record.tabID = nil }
        record.owner = owner
        sessions[sessionID] = record
    }

    /// Register the session's notification as outstanding and return its
    /// identifier. Idempotent: posting again reuses the identifier, so the
    /// notification center replaces rather than stacks.
    ///
    /// The text is recorded alongside, because a replacement notification also
    /// replaces what the menu bar should say about the session — the identifier
    /// staying the same is exactly why the old text must not survive it.
    public mutating func newNotification(
        sessionID: String,
        clearOnFocus: Bool = true,
        title: String = "",
        subtitle: String = "",
        body: String = "",
        now: Double,
        roundID: String? = nil
    ) -> String {
        let id = Self.notificationID(sessionID: sessionID)
        var record = sessions[sessionID] ?? SessionRecord()
        if !record.notificationIDs.contains(id) {
            record.notificationIDs.append(id)
        }
        record.clearOnFocus = clearOnFocus
        record.updatedAt = now
        record.title = title
        record.subtitle = subtitle
        record.body = body
        record.postedAt = now
        record.roundID = roundID
        // A replacement starts its own clock; the caller sets it.
        record.expiresAt = nil
        sessions[sessionID] = record
        return id
    }

    /// When a session's outstanding notification is due to go, or nil for never.
    public mutating func setExpiry(sessionID: String, at deadline: Double?) {
        guard sessions[sessionID]?.notificationIDs.isEmpty == false else { return }
        sessions[sessionID]?.expiresAt = deadline
    }

    /// Every outstanding deadline, judged against one moment: those that passed
    /// while nothing was there to act on them are forgotten and handed back, the
    /// rest come back with the seconds they have left. One `now` for both, so a
    /// deadline cannot fall between two readings of the clock and end up in
    /// neither, which would leave its notification with no timer at all.
    public mutating func resumeExpiries(now: Double) -> (
        overdue: [String], pending: [(identifier: String, remaining: Double)]
    ) {
        var overdue: [String] = []
        var pending: [(identifier: String, remaining: Double)] = []
        for sessionID in sessions.keys.sorted() {
            guard let record = sessions[sessionID], !record.notificationIDs.isEmpty,
                let deadline = record.expiresAt
            else { continue }
            if deadline <= now {
                overdue += takeNotifications(sessionID: sessionID)
            } else {
                pending += record.notificationIDs.map { ($0, deadline - now) }
            }
        }
        return (overdue, pending)
    }

    /// How many sessions are waiting on the user.
    ///
    /// Separate from `waitingSessions()` because the icon is refreshed on every
    /// state change and needs only this, while building the rows allocates one
    /// value per session and sorts them.
    public var waitingCount: Int {
        sessions.values.reduce(0) { $0 + ($1.notificationIDs.isEmpty ? 0 : 1) }
    }

    /// The sessions the menu bar lists, newest first.
    ///
    /// Ties break on the session id so the menu cannot reorder itself between
    /// two openings that happen in the same second — a moving target is worse
    /// than a stale one when the rows are click targets.
    public func waitingSessions() -> [WaitingSession] {
        sessions.compactMap { sessionID, record -> WaitingSession? in
            guard !record.notificationIDs.isEmpty else { return nil }
            return WaitingSession(
                sessionID: sessionID,
                title: record.title,
                subtitle: record.subtitle,
                body: record.body,
                postedAt: record.postedAt
            )
        }
        .sorted {
            $0.postedAt == $1.postedAt
                ? $0.sessionID < $1.sessionID
                : $0.postedAt > $1.postedAt
        }
    }

    /// Hand back a session's outstanding identifiers and forget them. The
    /// session record itself survives so its resolved tab is not lost.
    public mutating func takeNotifications(sessionID: String) -> [String] {
        guard var record = sessions[sessionID], !record.notificationIDs.isEmpty else {
            return []
        }
        let ids = record.notificationIDs
        record.notificationIDs = []
        record.clearNotice()
        sessions[sessionID] = record
        return ids
    }

    /// A late prompt from the same generation must not clear its own Stop's
    /// notification. Legacy notices have no round and are eligible for clearing.
    public mutating func takePreviousRoundNotifications(sessionID: String, roundID: String)
        -> [String]
    {
        guard sessions[sessionID]?.roundID != roundID else { return [] }
        return takeNotifications(sessionID: sessionID)
    }

    /// Drop one identifier — the notification center already removed it,
    /// because the user clicked it.
    public mutating func forgetNotification(_ notificationID: String) {
        for (sessionID, var record) in sessions {
            guard let index = record.notificationIDs.firstIndex(of: notificationID) else {
                continue
            }
            record.notificationIDs.remove(at: index)
            if record.notificationIDs.isEmpty { record.clearNotice() }
            sessions[sessionID] = record
            return
        }
    }

    /// What is on screen at this moment: each waiting session and when its
    /// notification was posted. Both questions this process asks about its
    /// notifications, which tab is selected and which are still delivered, are
    /// answered later, from another thread's callback. The answer is applied
    /// only to what was there when the question was put, so a notification
    /// posted in between is never withdrawn or forgotten on stale evidence.
    /// `postedBefore` leaves out the newest ones: posting is asynchronous, and a
    /// notification handed over a moment ago may not count as delivered yet.
    public func outstanding(postedBefore limit: Double = .infinity) -> [String: Double] {
        sessions.filter { !$0.value.notificationIDs.isEmpty && $0.value.postedAt < limit }
            .mapValues(\.postedAt)
    }

    private func unchanged(_ sessionID: String, since asked: [String: Double]?) -> Bool {
        guard let asked else { return true }
        return asked[sessionID] == sessions[sessionID]?.postedAt
    }

    /// Forget every identifier that is no longer among `delivered`, and return
    /// them. With `among`, only for sessions unchanged since that snapshot.
    ///
    /// The user can clear a notification from Notification Center without this
    /// process hearing about it — most reliably while the agent is not running
    /// at all. Bookkeeping that outlives the notification used to be invisible;
    /// with a count on the menu bar it is a standing lie.
    public mutating func forgetNotifications(
        notIn delivered: Set<String>, among asked: [String: Double]? = nil
    ) -> [String] {
        var gone: [String] = []
        for sessionID in sessions.keys.sorted() {
            guard var record = sessions[sessionID], !record.notificationIDs.isEmpty,
                unchanged(sessionID, since: asked)
            else {
                continue
            }
            let missing = record.notificationIDs.filter { !delivered.contains($0) }
            guard !missing.isEmpty else { continue }
            gone.append(contentsOf: missing)
            record.notificationIDs.removeAll { !delivered.contains($0) }
            if record.notificationIDs.isEmpty { record.clearNotice() }
            sessions[sessionID] = record
        }
        return gone
    }

    /// The session a notification identifier belongs to, for routing a click
    /// when the notification's own userInfo is unavailable.
    public func sessionID(forNotification notificationID: String) -> String? {
        sessions.first { $0.value.notificationIDs.contains(notificationID) }?.key
    }

    /// True when any session still has a notification on screen. Cheap, and
    /// worth checking before paying for an Apple Event round-trip.
    public var hasOutstandingNotifications: Bool {
        sessions.values.contains { !$0.notificationIDs.isEmpty }
    }

    /// Sessions that would be withdrawn if Ghostty came forward with this tab
    /// selected. Read-only, so the caller can decide whether the (expensive)
    /// tab query is even worth issuing.
    public func sessionsMatching(selectedTabID: String?) -> [String] {
        sessions.filter { _, record in
            guard !record.notificationIDs.isEmpty, record.clearOnFocus else { return false }
            guard let tabID = record.tabID else { return true }
            guard let selectedTabID else { return false }
            return tabID == selectedTabID
        }
        .keys.sorted()
    }

    /// True when switching between Ghostty tabs could withdraw something: an
    /// outstanding clear-on-focus notification whose tab is known. Checked
    /// before every poll of the selection, which costs an Apple Event.
    public var hasNotificationsOnKnownTabs: Bool {
        sessions.values.contains {
            !$0.notificationIDs.isEmpty && $0.clearOnFocus && $0.tabID != nil
        }
    }

    /// Each session a tab switch could clear, with its tab.
    public func waitingOnKnownTabs() -> [String: String] {
        sessions.compactMapValues { record in
            guard !record.notificationIDs.isEmpty, record.clearOnFocus else { return nil }
            return record.tabID
        }
    }

    /// Identifiers to withdraw in response to a focus change, forgetting them.
    ///
    /// A session with no resolved tab is always withdrawn when Ghostty comes
    /// forward: we cannot localize it, and the user is demonstrably looking at
    /// the terminal. A session with a known tab is withdrawn only on a positive
    /// match — when the tab query fails we leave it alone rather than clear a
    /// notification for a tab the user is not on. A session that opted out of
    /// clear-on-focus is never withdrawn this way at all.
    ///
    /// A tab switch inside Ghostty withdraws only a positive match. The
    /// no-tab fallback does not carry over: the user was in Ghostty all along,
    /// so moving between its tabs says nothing about a session that cannot be
    /// placed in one, and applying it would take such a notification down
    /// about a second after it was posted.
    ///
    /// With `among`, only sessions unchanged since that snapshot.
    public mutating func takeNotifications(
        for event: FocusEvent, among asked: [String: Double]? = nil
    ) -> [String] {
        let matching: [String]
        switch event {
        case .ghosttyActivated(let selectedTabID):
            matching = sessionsMatching(selectedTabID: selectedTabID)
        case .ghosttyTabSelected(let tabID):
            matching = sessionsMatching(selectedTabID: tabID).filter {
                sessions[$0]?.tabID != nil
            }
        case .otherAppActivated:
            return []
        }
        // Deterministic order so assertions do not depend on dictionary layout.
        return
            matching
            .filter { unchanged($0, since: asked) }
            .flatMap { takeNotifications(sessionID: $0) }
    }

    /// Forget sessions untouched for `maxAge` seconds. Outstanding identifiers
    /// are returned so the caller can withdraw notifications that will never be
    /// dismissed by focus or by a prompt — the session is gone.
    @discardableResult
    public mutating func prune(maxAge: Double, now: Double) -> [String] {
        let stale = sessions.filter { now - $0.value.updatedAt > maxAge }
        guard !stale.isEmpty else { return [] }
        var orphaned: [String] = []
        for sessionID in stale.keys.sorted() {
            orphaned.append(contentsOf: sessions[sessionID]?.notificationIDs ?? [])
            sessions[sessionID] = nil
        }
        return orphaned
    }
}
