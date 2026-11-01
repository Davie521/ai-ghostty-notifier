import Foundation

/// Finding a session's tab by its title, for a session no marker round-trip
/// has bound yet.
///
/// A Codex session is bound only at the end of a run long enough to notify:
/// while it works, Codex rewrites its tab title ten times a second (a spinner
/// in front), so a marker never holds long enough to be found. A nudge comes
/// part-way through, often before any such run. What stays put is the rest of
/// the title: Codex shows "<spinner> <thread name> | <folder>", with the
/// thread name its database holds and the nudge reads; Claude Code shows
/// "<status glyph> <session title>". Ghostty may put 🔔 in front of either.
public enum TabTitleMatch {
    /// The one tab whose title, without the glyphs in front, is `title` or
    /// begins with `title + " | "`. Nil when none does, and when more than one
    /// does: two sessions with one name must not be told apart by guessing.
    ///
    /// Both sides lose their glyph words in front the same way, so a session
    /// named "🚀 Release" still finds "⠙ 🚀 Release | repo"; a name that is
    /// only glyphs, or a single character, is too little to go by.
    public static func tab(titled title: String, among tabs: [TerminalTab]) -> String? {
        let wanted = stripped(title)
        guard wanted.count >= 2 else { return nil }
        let matches = tabs.filter { tab in
            let core = stripped(tab.title)
            return core == wanted || core.hasPrefix(wanted + " | ")
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// `title` without the words in front that hold no letter or digit:
    /// spinners, status glyphs, Ghostty's bell.
    static func stripped(_ title: String) -> String {
        var remaining = words(title)[...]
        while let first = remaining.first,
            !first.contains(where: { $0.isLetter || $0.isNumber })
        {
            remaining.removeFirst()
        }
        return remaining.joined(separator: " ")
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" })
    }
}
