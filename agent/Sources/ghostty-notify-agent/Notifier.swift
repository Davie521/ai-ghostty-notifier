import Foundation
import NotifyCore
import UserNotifications

/// Thin wrapper over the notification center. Everything here is I/O; the
/// decisions about *which* identifiers to post and withdraw live in
/// `NotifyCore` where they are testable.
///
/// UNUserNotificationCenter refuses to serve a process with no bundle identity,
/// and macOS refuses to grant authorization to a bundle in a temporary
/// directory — verified the hard way. The install script therefore assembles a
/// real .app under the plugin root; see scripts/build-agent.sh.
@MainActor
final class Notifier {
    /// Resolved on each use, never stored at init.
    ///
    /// `UNUserNotificationCenter.current()` must not be touched before the app
    /// has finished launching. This class is constructed from `main.swift`,
    /// before `NSApplication.run()`, and a stored property would make that first
    /// touch happen there — at which point the notification system has not
    /// registered the bundle yet and permanently answers every authorization
    /// request with "Notifications are not allowed for this application", with
    /// no dialog and no entry in System Settings. It is a singleton, so
    /// re-resolving costs nothing.
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    /// Sendable because the notification center's completion handlers run off
    /// the main thread and still need to report failures.
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// Registers the "Go to tab" button. `.foreground` is what brings this
    /// (accessory) process forward, which is what earns the Apple Event we send
    /// next the right to reorder Ghostty's windows.
    func registerCategories() {
        let goto = UNNotificationAction(
            identifier: AgentConstants.gotoActionID,
            title: UIText.text("Go to tab"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: AgentConstants.categoryID,
            actions: [goto],
            intentIdentifiers: [],
            // Without .customDismissAction macOS tells us nothing when the user
            // clears the notification themselves, so the agent goes on believing
            // it is on screen. The delegate already handles
            // UNNotificationDismissActionIdentifier; this is what makes it fire.
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    /// Identifiers macOS still has on screen.
    ///
    /// The reconciliation source for bookkeeping that outlived its
    /// notification — a "Clear All" while this process was not running arrives
    /// no other way.
    func deliveredIdentifiers(_ completion: @escaping @MainActor (Set<String>) -> Void) {
        center.getDeliveredNotifications { delivered in
            let identifiers = Set(delivered.map { $0.request.identifier })
            Task { @MainActor in completion(identifiers) }
        }
    }

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        center.delegate = delegate
    }

    /// The three ways an authorization request can come back. `granted=false`
    /// alone is ambiguous: with an error attached it means the system refused
    /// to process the request — no dialog appeared, nothing was recorded, and a
    /// later launch can succeed. Without one it means the dialog was shown and
    /// the user said no, which macOS makes permanent for this bundle
    /// identifier. Collapsing the two had the install script telling users
    /// their identifier was burned when a plain retry would have worked.
    enum AuthorizationAnswer {
        case granted
        case denied
        case unavailable(String)
    }

    func requestAuthorization(_ completion: @escaping @MainActor (AuthorizationAnswer) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            Task { @MainActor in
                if let error {
                    log("authorization error: \(error.localizedDescription)")
                    completion(.unavailable(error.localizedDescription))
                } else {
                    completion(granted ? .granted : .denied)
                }
            }
        }
    }

    /// The style macOS has recorded for this app: `banner`, `alert` or `none`.
    ///
    /// Read-only by necessity. `NSUserNotificationAlertStyle` only ever applied
    /// to the deprecated NSUserNotification API, and Apple has confirmed the
    /// style cannot be set programmatically for UNUserNotificationCenter apps —
    /// verified here by shipping a fresh bundle identifier that carried the key
    /// from first registration and still got Banner. All an app can do is notice
    /// and say so.
    func currentAlertStyle(_ completion: @escaping @MainActor (String) -> Void) {
        currentSettings { _, style in completion(style) }
    }

    /// The style, and whether notifications are allowed: nil while macOS has no
    /// answer on record. Reads only. It never asks, so it never prompts.
    func currentSettings(_ completion: @escaping @MainActor (Bool?, String) -> Void) {
        center.getNotificationSettings { settings in
            let name: String
            switch settings.alertStyle {
            case .alert: name = "alert"
            case .banner: name = "banner"
            case .none: name = "none"
            @unknown default: name = "unknown"
            }
            let authorized: Bool?
            switch settings.authorizationStatus {
            case .authorized, .provisional: authorized = true
            case .denied: authorized = false
            default: authorized = nil
            }
            Task { @MainActor in completion(authorized, name) }
        }
    }

    func post(identifier: String, sessionID: String, request: NotifyRequest) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.subtitle = request.subtitle
        content.body = request.body
        content.categoryIdentifier = AgentConstants.categoryID
        // Groups a session's notifications together in Notification Center, the
        // way `-group ghostty-notify-<session>` did. Replacement itself comes
        // from reusing the identifier, not from this.
        content.threadIdentifier = "ghostty-notify-\(sessionID)"
        // Carried on the notification itself so a click can still be routed to a
        // session after the agent restarted and reloaded its bookkeeping.
        content.userInfo = ["session_id": sessionID]
        if let tabID = request.tabID { content.userInfo["tab_id"] = tabID }
        if let sound = request.sound {
            content.sound = Self.sound(named: sound)
        }

        // trigger: nil delivers immediately. Re-adding an identifier that is
        // already delivered replaces it, which is the group behaviour the shell
        // backends had.
        let notification = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)
        center.add(notification) { [log] error in
            if let error {
                log("post \(identifier) failed: \(error.localizedDescription)")
            }
        }
    }

    /// The shell backends speak `/System/Library/Sounds` vocabulary ("Glass",
    /// "Ping"). UNNotificationSound resolves a custom name against the app
    /// bundle instead, so scripts/build-agent.sh copies those .aiff files into
    /// Contents/Resources and the extension is added back here. A name that did
    /// not get bundled would resolve to nothing at all, so fall back to the
    /// system default rather than posting silently.
    private static func sound(named name: String) -> UNNotificationSound {
        let file = name.hasSuffix(".aiff") ? name : name + ".aiff"
        guard Bundle.main.url(forResource: file, withExtension: nil) != nil else {
            return .default
        }
        return UNNotificationSound(named: UNNotificationSoundName(file))
    }

    /// Removes both delivered and still-pending notifications.
    ///
    /// Delivery through `center.add` is asynchronous, so a dismiss that arrives
    /// in the same drain batch as its notify can reach the center first. Without
    /// the pending removal that dismiss is a no-op and the banner appears
    /// afterwards with nothing left tracking it.
    func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        log("withdrew \(identifiers.joined(separator: ","))")
    }
}
