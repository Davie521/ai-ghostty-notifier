import Foundation

/// Text the user reads, in their language.
///
/// Every mode of this executable runs from inside ClaudeGhosttyNotify.app, so
/// `Bundle.main` is the app bundle, and its `<language>.lproj/Localizable.strings`
/// are the translations; macOS picks the language from the user's list, per
/// app. The English is the key: `swift test` and a bare fixture bundle have no
/// strings and get the English back unchanged, and so does any key a
/// translation lacks. The strings files live in agent/Resources and
/// scripts/build-agent.sh copies them into the bundle.
public enum UIText {
    /// `english` is both the key and what comes back when there is no
    /// translation. A `key` that is not itself English carries its English in
    /// `default`, for the one text too long to be its own key.
    public static func text(
        _ key: String, default english: String? = nil, in bundle: Bundle = .main
    ) -> String {
        bundle.localizedString(forKey: key, value: english ?? key, table: nil)
    }

    /// A format, then `String(format:)`. Translations keep the specifiers.
    public static func format(
        _ key: String, in bundle: Bundle = .main, _ arguments: CVarArg...
    ) -> String {
        String(format: text(key, in: bundle), arguments: arguments)
    }
}
