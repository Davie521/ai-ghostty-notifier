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
    /// The AppleScript listing has no such window.
    case unknown

    /// Ghostty names its windows by their own stable ids, which nothing
    /// outside Ghostty can see; the window server knows window numbers and
    /// Spaces but, without the Screen Recording permission, no titles. The
    /// two sides meet on what both can tell: the order, front to back, which
    /// Ghostty's AppleScript takes from AppKit's ordered windows; and, for
    /// windows in view, the title, which Accessibility reads. So a window
    /// whose title Accessibility sees is showing. Otherwise the windows the
    /// listing has and Accessibility lacks are paired, in order, with the
    /// ordered windows on hidden Spaces — exact when the two counts agree,
    /// else every hidden window stays a candidate and a jump confirms after
    /// it travels. Titles are counted, not merely matched, so two windows
    /// titled alike with one of them hidden do not pass for both showing.
    public static func of(
        _ windowID: String, scripted: [ScriptedWindow], ordered: [OrderedWindow],
        seen: [SeenWindow], visibleSpaces: Set<UInt64>
    ) -> WindowPlace {
        guard let targetIndex = scripted.firstIndex(where: { $0.id == windowID }) else {
            return .unknown
        }
        var unclaimed: [String: Int] = [:]
        for window in seen where !window.title.isEmpty {
            unclaimed[window.title, default: 0] += 1
        }
        var showing = [Bool](repeating: false, count: scripted.count)
        for (index, window) in scripted.enumerated() where !window.title.isEmpty {
            guard let count = unclaimed[window.title], count > 0 else { continue }
            unclaimed[window.title] = count - 1
            showing[index] = true
        }
        if showing[targetIndex] { return .showing }

        let hidden = ordered.filter {
            !$0.spaces.isEmpty && !$0.spaces.contains(where: visibleSpaces.contains)
        }
        // Nothing of Ghostty's is out of view, whatever the titles said.
        if hidden.isEmpty { return .showing }

        let hiddenIndices = scripted.indices.filter { !showing[$0] }
        if hiddenIndices.count == hidden.count,
            let position = hiddenIndices.firstIndex(of: targetIndex)
        {
            var candidates = hidden
            let likely = candidates.remove(at: position)
            return .hidden(candidates: [likely] + candidates)
        }
        return .hidden(candidates: hidden)
    }
}
