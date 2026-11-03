import Testing

@testable import NotifyCore

@Suite struct NotificationSoundTests {
    static func bundle(_ files: Set<String>) -> (String) -> Bool { { files.contains($0) } }

    /// What scripts/make-sounds.py writes and CI looks for in the bundle.
    @Test func theOwnSoundsAreTheOnesTheBuildMakes() {
        #expect(NotificationSound.ownFiles["Glass"] == "ghostty-notify-done.wav")
        #expect(NotificationSound.ownFiles["Ping"] == "ghostty-notify-nudge.wav")
    }

    // A release bundles only the app's own sounds.
    @Test func aReleasePlaysItsOwnSounds() {
        let release = Self.bundle(["ghostty-notify-done.wav", "ghostty-notify-nudge.wav"])
        #expect(
            NotificationSound.file(named: "Glass", bundled: release) == "ghostty-notify-done.wav")
        #expect(
            NotificationSound.file(named: "Ping", bundled: release) == "ghostty-notify-nudge.wav")
        #expect(NotificationSound.file(named: "Hero", bundled: release) == nil)
    }

    // A local build has Apple's too; the own sounds still win for the two tiers.
    @Test func aLocalBuildStillPrefersTheOwnSounds() {
        let local = Self.bundle([
            "ghostty-notify-done.wav", "ghostty-notify-nudge.wav", "Glass.aiff", "Ping.aiff",
            "Hero.aiff",
        ])
        #expect(NotificationSound.file(named: "Glass", bundled: local) == "ghostty-notify-done.wav")
        #expect(NotificationSound.file(named: "Ping", bundled: local) == "ghostty-notify-nudge.wav")
        #expect(NotificationSound.file(named: "Hero", bundled: local) == "Hero.aiff")
        #expect(NotificationSound.file(named: "Hero.aiff", bundled: local) == "Hero.aiff")
    }

    // A bundle built before the own sounds existed behaves as it always did.
    @Test func withoutTheOwnSoundsItFallsBackAsBefore() {
        let older = Self.bundle(["Glass.aiff"])
        #expect(NotificationSound.file(named: "Glass", bundled: older) == "Glass.aiff")
        #expect(NotificationSound.file(named: "Ping", bundled: older) == nil)
    }
}
