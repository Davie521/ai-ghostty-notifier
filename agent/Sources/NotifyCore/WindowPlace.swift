import Foundation

/// One of Ghostty's windows as its AppleScript lists them, front to back. A
/// window here is a whole tab group; `title` is the title of the tab it shows.
public struct ScriptedWindow: Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

extension ScriptedWindow {
    /// The locate script's reply: the id of the window holding the tab, then
    /// every window's id and title, records split by U+001E and fields by
    /// U+001F, which no title contains. Nil is a failed script, which is
    /// "don't know", never "not there": the script says that with an empty
    /// first field, and says "?" when a window or tab could not be read on
    /// the way — the tab may be the one that could not be read.
    public static func locateReply(_ answer: String?) -> (TabJump.Probe, [ScriptedWindow]) {
        guard let answer else { return (.unknown, []) }
        var records = answer.split(separator: "\u{1E}", omittingEmptySubsequences: false)
        guard !records.isEmpty else { return (.unknown, []) }
        let found = String(records.removeFirst())
        let windows = records.compactMap { record -> ScriptedWindow? in
            let fields = record.split(
                separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard let id = fields.first, !id.isEmpty else { return nil }
            return ScriptedWindow(id: String(id), title: fields.count > 1 ? String(fields[1]) : "")
        }
        guard !found.isEmpty else { return (.notFound, windows) }
        guard found != "?" else { return (.unknown, windows) }
        return (.found(window: found), windows)
    }
}

/// One of Ghostty's windows as the window server orders them, front to back:
/// only the window of a tab group's selected tab is ordered in, so there is one
/// of these per group. `spaces` are the Spaces it sits on.
public struct OrderedWindow: Equatable, Sendable {
    public let number: UInt32
    public let spaces: [UInt64]

    public init(number: UInt32, spaces: [UInt64]) {
        self.number = number
        self.spaces = spaces
    }
}

/// One of Ghostty's windows as Accessibility shows it. Accessibility lists
/// only windows on Spaces in view, which is what makes it useful here.
public struct SeenWindow: Equatable, Sendable {
    public let number: UInt32
    public let title: String

    public init(number: UInt32, title: String) {
        self.number = number
        self.title = title
    }
}

/// Where the window a jump wants is.
public enum WindowPlace: Equatable, Sendable {
    /// On a Space in view: focusing it stays where the user is.
    case showing
    /// Out of view. The ordered windows on hidden Spaces that may be it, the
    /// most likely first.
    case hidden(candidates: [OrderedWindow])
    /// The two lists do not pair: they differ in length, or a title in view
    /// contradicts the pairing. A window opening or closing, or a title that
    /// changed between the two reads — a busy session retitles its tab twice
    /// a second — both look like this, and both pass; a fresh read decides.
    case unsettled
    /// The listing has no such window.
    case unknown

    /// Ghostty names its windows by their own stable ids, which nothing
    /// outside Ghostty can see; the window server knows window numbers and
    /// Spaces but, without the Screen Recording permission, no titles. The
    /// two sides meet on the order: Ghostty's AppleScript lists its windows
    /// front to back in AppKit's order, which is the window server's, and the
    /// window server lists one ordered window per tab group in that order too.
    /// So when the two lists are as long as each other they pair one to one,
    /// and the pairing is checked against the titles Accessibility reads for
    /// the windows in view; titles cannot pair windows themselves, because
    /// shells in different windows are often titled exactly alike.
    ///
    /// When the lengths differ or a title contradicts the pairing, nothing is
    /// concluded from titles alone: a window whose title just changed looks
    /// exactly like one that is out of view, and travelling on that guess
    /// would switch a display for nothing.
    ///
    /// The window server also lists Ghostty's windows that are not terminals —
    /// an About box, an open menu — which Ghostty's list leaves out. One in
    /// view that Accessibility does not show as a window titled like one of
    /// Ghostty's is set aside before pairing. One out of view cannot be told
    /// apart, and leaves the lists unsettled.
    ///
    /// `seen` is nil without the Accessibility permission. The order still
    /// places the window then, which is how a jump knows it needed the
    /// permission; there are just no titles to check the pairing against.
    public static func of(
        _ windowID: String, scripted: [ScriptedWindow], ordered: [OrderedWindow],
        seen: [SeenWindow]?, visibleSpaces: Set<UInt64>
    ) -> WindowPlace {
        guard let targetIndex = scripted.firstIndex(where: { $0.id == windowID }) else {
            return .unknown
        }
        let inView: (OrderedWindow) -> Bool = { $0.spaces.contains(where: visibleSpaces.contains) }
        let listedTitles = Set(scripted.map(\.title))
        var seenTitles: [UInt32: String]?
        if let seen {
            seenTitles = Dictionary(
                seen.map { ($0.number, $0.title) }, uniquingKeysWith: { a, _ in a })
        }
        let placed = ordered.filter { window in
            guard !window.spaces.isEmpty else { return false }
            guard let seenTitles, inView(window) else { return true }
            guard let title = seenTitles[window.number] else { return false }
            return listedTitles.contains(title)
        }
        let hidden = placed.filter { !inView($0) }
        // Nothing of Ghostty's is out of view.
        if hidden.isEmpty { return .showing }

        guard placed.count == scripted.count, titlesAgree(scripted, placed, seen ?? []) else {
            return .unsettled
        }
        let window = placed[targetIndex]
        if inView(window) { return .showing }
        return .hidden(candidates: [window] + hidden.filter { $0 != window })
    }

    /// Whether every window in view pairs with a listed window of its title.
    private static func titlesAgree(
        _ scripted: [ScriptedWindow], _ placed: [OrderedWindow], _ seen: [SeenWindow]
    ) -> Bool {
        var titles: [UInt32: String] = [:]
        for window in seen where titles[window.number] == nil {
            titles[window.number] = window.title
        }
        return zip(scripted, placed).allSatisfy { listed, window in
            titles[window.number].map { $0 == listed.title } ?? true
        }
    }
}
