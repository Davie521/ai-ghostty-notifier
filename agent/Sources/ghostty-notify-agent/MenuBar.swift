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
    private let onOpen: () -> Void

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
        onOpenLog: @escaping () -> Void,
        onOpen: @escaping () -> Void = {}
    ) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.iconState = iconState
        self.menuStatus = menuStatus
        self.onJump = onJump
        self.onShowGuidance = onShowGuidance
        self.onOpenSettings = onOpenSettings
        self.onOpenLog = onOpenLog
        self.onOpen = onOpen
        // Sized from the bar AppKit actually gave us rather than a constant:
        // the thickness differs with accessibility text sizing and on notched
        // displays. The inset is the usual breathing room around a menu bar
        // glyph.
        let height = max(12, NSStatusBar.system.thickness - 5)
        self.markImage = GhostMark.image(height: height, crossedOut: false)
        self.crossedOutImage = GhostMark.image(height: height, crossedOut: true)
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
        onOpen()
        // One snapshot for the icon and the rows: nothing can change between
        // them, and building the rows is the expensive half.
        let current = menuStatus()
        apply(current.menuBarState)
        let now = Date().timeIntervalSince1970
        menu.removeAllItems()

        menu.addItem(header(AgentConstants.displayName))
        addStatusBlock(to: menu, status: current)

        menu.addItem(.separator())
        addWaitingSection(to: menu, waiting: current.waiting, now: now)

        menu.addItem(.separator())
        // Always here, not only when something is wrong: it is also where the
        // sound, the Focus modes and the lock screen are set.
        menu.addItem(
            action(UIText.text("Notification Settings…"), symbol: "bell", #selector(openSettings)))
        menu.addItem(
            action(
                UIText.text("Setup Guidance…"), symbol: "questionmark.circle",
                #selector(showGuidance)))
        menu.addItem(action(UIText.text("Open Log"), symbol: "doc.text", #selector(openLog)))
        menu.addItem(.separator())
        let quit = action(
            UIText.format("Quit %@", AgentConstants.displayName), symbol: "power", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// Permission and alert style, then the sessions-seen count in small print.
    ///
    /// Grey means fine. A problem the user can fix is a button, which is also
    /// what keeps it at full strength: AppKit dims a disabled item, symbol and
    /// all, to the same grey as "everything is in order".
    private func addStatusBlock(to menu: NSMenu, status: AgentStatus) {
        let block = MenuStatusLine.block(
            permission: status.permission, alertStyle: status.alertStyle)
        for line in block {
            let entry =
                line.opensSettings
                ? action(line.text, #selector(openSettings)) : disabled(line.text)
            entry.image = Self.statusSymbol(line.tone)
            menu.addItem(entry)
        }
        let seen = MenuText.sessionsSeen(status.trackedSessions)
        let small = disabled(seen)
        small.attributedTitle = NSAttributedString(
            string: seen,
            attributes: [
                .font: NSFont.systemFont(ofSize: Self.baseSize - 2),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        menu.addItem(small)
    }

    /// The sessions waiting on the user, each row a way back to its tab.
    private func addWaitingSection(to menu: NSMenu, waiting: [WaitingSession], now: Double) {
        guard !waiting.isEmpty else {
            menu.addItem(disabled(UIText.text("No sessions waiting")))
            return
        }

        menu.addItem(header(MenuText.waitingHeader(waiting.count)))
        for session in waiting {
            let lines = session.menuLines(now: now)
            // A plain title as well as the attributed one: NSMenu's keyboard
            // type-select matches on `title`, and a row with only an
            // `attributedTitle` cannot be reached from the keyboard at all. It
            // leads with the subtitle, since every row starts with the same
            // app name.
            let plain = lines.filter { $0.role != .title }.map(\.text).joined(separator: " — ")
            let entry = NSMenuItem(
                title: plain, action: #selector(jumpToSession(_:)), keyEquivalent: "")
            entry.attributedTitle = Self.rowText(lines)
            entry.toolTip = session.clippedText()
            entry.target = self
            entry.representedObject = session.sessionID
            menu.addItem(entry)
        }
    }

    /// Derived from the menu font rather than fixed points, so everything
    /// scales with the rest of the menu when the user enlarges system text.
    private static var baseSize: CGFloat { NSFont.menuFont(ofSize: 0).pointSize }

    /// One row, in the notification's own order: title, subtitle, body.
    ///
    /// Not in the notification's own emphasis, though. The title is the app
    /// name — "Claude" on nearly every row — so drawing it bold made the one
    /// line that tells rows apart the least the loudest. It is small print
    /// with the time beside it, the way Notification Center heads a
    /// notification with the app and the time; the subtitle, which names the
    /// session and the project, is the line that stands out.
    private static func rowText(_ lines: [NotificationLine]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.lineBreakMode = .byTruncatingTail
        let base = baseSize

        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            // Styled by what the line *is*. Empty lines are dropped, so a body
            // can end up where a subtitle would have been and position alone
            // would style it wrongly.
            let font: NSFont
            let color: NSColor
            switch line.role {
            case .title:
                font = NSFont.systemFont(ofSize: base - 2)
                color = .secondaryLabelColor
            case .subtitle:
                font = NSFont.systemFont(ofSize: base, weight: .semibold)
                color = .labelColor
            case .body:
                font = NSFont.systemFont(ofSize: base - 1)
                color = .secondaryLabelColor
            }
            text.append(
                NSAttributedString(
                    string: line.text,
                    attributes: [
                        .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                    ]))
        }
        return text
    }

    /// The symbol beside a status line. Coloured where colour carries the
    /// meaning — green for fine, orange for a problem — and a template
    /// otherwise, so it takes the text colour.
    private static func statusSymbol(_ tone: MenuStatusTone) -> NSImage? {
        switch tone {
        case .ok:
            return symbol(
                "checkmark.circle.fill", label: UIText.text("OK"), colors: [.white, .systemGreen])
        case .checking: return symbol("clock", label: UIText.text("Checking"))
        case .unrecognised: return symbol("circle.dashed", label: UIText.text("Unknown"))
        case .problem:
            return symbol(
                "exclamationmark.triangle.fill", label: UIText.text("Problem"),
                colors: [.white, .systemOrange])
        }
    }

    /// Coloured through a symbol configuration rather than painted over, and
    /// that matters: the menu lines up the titles of a section's image-less
    /// items — the small print under the status — with those beside a
    /// *symbol*, and a repainted image is no longer one. The small print then
    /// sat under the tick in one state and under the text in another.
    private static func symbol(_ name: String, label: String?, colors: [NSColor] = []) -> NSImage? {
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: label) else {
            return nil
        }
        guard !colors.isEmpty else { return glyph }
        return glyph.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: colors))
    }

    /// A section title — the system's own style where there is one.
    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        return disabled(title)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(
        _ title: String, symbol: String? = nil, _ selector: Selector
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        if let symbol { entry.image = Self.symbol(symbol, label: nil) }
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
