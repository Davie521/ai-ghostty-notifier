import AppKit
import Foundation
import NotifyCore

/// What the menu shows. Gathered fresh every time the menu opens, so it can
/// never display a stale "everything is fine".
struct AgentStatus {
    var permission: NotificationPermission
    /// "alert", "banner", "none", "unknown", or "" before it has been read.
    var alertStyle: String
    /// Sessions with a notification still on screen, newest first.
    var waiting: [WaitingSession]
    var trackedSessions: Int

    var menuBarState: MenuBarState {
        MenuBarState.resolve(
            permission: permission, alertStyle: alertStyle, waiting: waiting.count)
    }
}

/// The menu bar item.
///
/// Exists because a background agent with no UI gives the user no way to tell
/// "running and working" from "running and silently useless" — which is exactly
/// the state an unanswered permission prompt, a denied Automation grant, or the
/// Temporary alert style leaves it in. Those are invisible without this.
///
/// It carries live state as well as diagnosis: the icon counts the sessions
/// waiting on the user and the menu names them, each row jumping to its tab.
/// That is the only persistent way back to a session under the Temporary alert
/// style, where the notification itself slides away before it can be clicked.
///
/// Opt out with GHOSTTY_NOTIFY_MENU_BAR=0.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    /// Cheap: what the icon needs, and nothing more. Called on every state
    /// change.
    private let iconState: () -> MenuBarState
    /// Expensive: builds and sorts a row per waiting session. Called when the
    /// menu opens.
    private let menuStatus: () -> AgentStatus
    private let onJump: (String) -> Void
    private let onShowGuidance: () -> Void
    private let onOpenSettings: () -> Void
    private let onOpenLog: () -> Void

    /// There are exactly two icons; drawing them once beats re-running the
    /// bezier construction on every state change.
    private let markImage: NSImage
    private let crossedOutImage: NSImage
    /// Last rendered appearance, so a refresh that changes nothing does not
    /// touch the status item. Refresh is called from every state change,
    /// including the hourly prune.
    private var rendered: MenuBarState?

    static func isEnabled(env: [String: String]) -> Bool {
        switch env["GHOSTTY_NOTIFY_MENU_BAR"] {
        case nil: return true
        case let value?:
            return !["0", "false", "no", "off"].contains(value.lowercased())
        }
    }

    init(
        iconState: @escaping () -> MenuBarState,
        menuStatus: @escaping () -> AgentStatus,
        onJump: @escaping (String) -> Void,
        onShowGuidance: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenLog: @escaping () -> Void
    ) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.iconState = iconState
        self.menuStatus = menuStatus
        self.onJump = onJump
        self.onShowGuidance = onShowGuidance
        self.onOpenSettings = onOpenSettings
        self.onOpenLog = onOpenLog
        // Sized from the bar AppKit actually gave us rather than a constant:
        // the thickness differs with accessibility text sizing and on notched
        // displays. The inset is the usual breathing room around a menu bar
        // glyph.
        let height = max(12, NSStatusBar.system.thickness - 5)
        self.markImage = ClaudeMark.image(height: height, crossedOut: false)
        self.crossedOutImage = ClaudeMark.image(height: height, crossedOut: true)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        refresh()
    }

    /// Bring the icon up to date with the agent's state.
    ///
    /// Called from every state change rather than only from `menuNeedsUpdate`.
    /// Refreshing on menu-open alone meant the icon was a snapshot of the last
    /// time the user opened the menu: a notification could arrive, be withdrawn,
    /// and the authorization answer land, without the icon ever moving.
    func refresh() {
        apply(iconState())
    }

    private func apply(_ state: MenuBarState) {
        guard state != rendered else { return }
        rendered = state

        let image = state.icon == .markCrossedOut ? crossedOutImage : markImage
        image.accessibilityDescription = state.accessibilityDescription
        item.button?.image = image
        // A leading space is the gap between icon and count; an empty title
        // gives back the width, which is why an idle agent shows no number.
        let badge = state.badgeText
        item.button?.title = badge.isEmpty ? "" : " \(badge)"
        // This overrides both the image description and the visible count, so
        // the description has to carry the count itself.
        item.button?.setAccessibilityLabel(state.accessibilityDescription)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // One snapshot for the icon and the rows: nothing can change between
        // them, and building the rows is the expensive half.
        let current = menuStatus()
        apply(current.menuBarState)
        let now = Date().timeIntervalSince1970
        menu.removeAllItems()

        menu.addItem(disabled("Claude Ghostty Notify"))
        menu.addItem(.separator())

        switch current.permission {
        case .granted:
            menu.addItem(disabled("✓  Notifications allowed"))
        case .denied:
            menu.addItem(disabled("⚠  Notifications not allowed"))
        case .unavailable:
            // Not the user's answer: the system never asked. Saying "not
            // allowed" here would send them to a System Settings row that does
            // not exist yet, when a relaunch is what fixes it.
            menu.addItem(disabled("⚠  Notification permission unavailable — relaunch"))
        case .unknown:
            menu.addItem(disabled("…  Notification permission: checking"))
        }

        switch current.alertStyle {
        case "alert":
            menu.addItem(disabled("✓  Alert style: Persistent"))
        case "banner":
            // The one problem the user can actually fix, so it is the one item
            // that does something when clicked.
            menu.addItem(action("⚠  Alert style: Temporary — fix…", #selector(openSettings)))
        case "none":
            menu.addItem(action("⚠  Alerts turned off — fix…", #selector(openSettings)))
        case "":
            menu.addItem(disabled("…  Alert style: checking"))
        default:
            // Read, but macOS named a style this build does not know. Distinct
            // from "checking", which would otherwise sit there forever claiming
            // an answer is still coming.
            menu.addItem(disabled("?  Alert style: \(current.alertStyle)"))
        }

        menu.addItem(.separator())
        addWaitingSection(to: menu, waiting: current.waiting, now: now)

        menu.addItem(.separator())
        // Honest about the window: sessions are forgotten after 24h, so this is
        // "seen recently", not "open right now".
        menu.addItem(
            disabled(
                current.trackedSessions == 1
                    ? "1 session tracked · last 24h"
                    : "\(current.trackedSessions) sessions tracked · last 24h"))

        menu.addItem(.separator())
        menu.addItem(action("Setup guidance…", #selector(showGuidance)))
        menu.addItem(action("Open log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit)))
    }

    /// The sessions waiting on the user, each row a way back to its tab.
    private func addWaitingSection(to menu: NSMenu, waiting: [WaitingSession], now: Double) {
        guard !waiting.isEmpty else {
            menu.addItem(disabled("No notifications waiting"))
            return
        }

        menu.addItem(
            disabled(waiting.count == 1 ? "1 session waiting" : "\(waiting.count) sessions waiting")
        )
        for session in waiting {
            let lines = session.notificationLines()
            let plain =
                lines.isEmpty
                ? session.fallbackLabel : lines.map(\.text).joined(separator: " — ")
            // A plain title as well as the attributed one: NSMenu's keyboard
            // type-select matches on `title`, and a row with only an
            // `attributedTitle` cannot be reached from the keyboard at all.
            let entry = NSMenuItem(
                title: plain, action: #selector(jumpToSession(_:)), keyEquivalent: "")
            entry.attributedTitle = Self.rowText(
                lines: lines, fallback: session.fallbackLabel,
                time: session.relativeTime(now: now))
            entry.target = self
            entry.representedObject = session.sessionID
            menu.addItem(entry)
        }
    }

    /// One row, laid out like the notification it stands in for: the title in
    /// bold with the time beside it, then the subtitle, then the body.
    ///
    /// Same content and same order as the banner, because that is what makes the
    /// row recognisable as the thing the user missed rather than a second,
    /// slightly different account of it.
    private static func rowText(
        lines: [NotificationLine], fallback: String, time: String
    ) -> NSAttributedString {
        let shown =
            lines.isEmpty ? [NotificationLine(role: .title, text: fallback)] : lines
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.lineBreakMode = .byTruncatingTail
        // Derived from the menu font rather than fixed points, so the rows grow
        // with the rest of the menu when the user scales system text.
        let base = NSFont.menuFont(ofSize: 0).pointSize

        let text = NSMutableAttributedString()
        for (index, line) in shown.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            // Styled by what the line *is*. Empty lines are dropped, so a body
            // can end up where a subtitle would have been and position alone
            // would style it wrongly.
            let font: NSFont
            let color: NSColor
            switch line.role {
            case .title:
                font = NSFont.systemFont(ofSize: base, weight: .semibold)
                color = .labelColor
            case .subtitle:
                font = NSFont.systemFont(ofSize: base - 1)
                color = .labelColor
            case .body:
                font = NSFont.systemFont(ofSize: base - 2)
                color = .secondaryLabelColor
            }
            text.append(
                NSAttributedString(
                    string: line.text,
                    attributes: [
                        .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                    ]))
            if index == 0, !time.isEmpty {
                text.append(
                    NSAttributedString(
                        string: "   " + time,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: base - 2),
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .paragraphStyle: paragraph,
                        ]))
            }
        }
        return text
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    // MARK: - Actions

    @objc private func jumpToSession(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String else { return }
        onJump(sessionID)
    }

    @objc private func showGuidance() { onShowGuidance() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func openLog() { onOpenLog() }
    @objc private func quit() { Agent.requestTermination() }
}
