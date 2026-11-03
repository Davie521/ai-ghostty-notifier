import Foundation

/// Which sound file the resident agent plays for a request's sound name.
///
/// The hooks name sounds in `/System/Library/Sounds` vocabulary — "Glass" when
/// a long run finishes, "Ping" when a session needs you — because that is what
/// the display-only fallbacks (terminal-notifier, `display notification`) can
/// play. The agent has its own sounds for those two, made at build time by
/// scripts/make-sounds.py; since they are the project's own, a published
/// release carries them, which it may not do with Apple's.
///
/// UNNotificationSound resolves a name against the app bundle only, so a file
/// the bundle lacks would play nothing at all. `nil` means "play the system
/// default sound" instead.
public enum NotificationSound {
    public static let ownFiles: [String: String] = [
        "Glass": "ghostty-notify-done.wav",
        "Ping": "ghostty-notify-nudge.wav",
    ]

    /// `bundled` says whether the app bundle has a resource of that file name.
    public static func file(named name: String, bundled: (String) -> Bool) -> String? {
        if let own = ownFiles[name], bundled(own) { return own }
        // A local build also bundles Apple's sounds, under their own names.
        let system = name.hasSuffix(".aiff") ? name : name + ".aiff"
        return bundled(system) ? system : nil
    }
}
