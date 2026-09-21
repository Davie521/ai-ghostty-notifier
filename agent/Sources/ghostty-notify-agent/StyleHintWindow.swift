import AppKit
import Foundation

/// The alert-style setup guidance, as a NON-modal window.
///
/// It started life as an `NSAlert.runModal()`, which froze the whole agent:
/// measured by sending a ping while the dialog was up and getting no answer
/// until it was dismissed. A modal run loop does not service this process's
/// spool watcher or timers, so a setup dialog the user ignored would silently
/// stop every notification — the same failure shape as the synchronous Apple
/// Event that used to block the main actor.
///
/// So: a real window, ordered front, with target/action buttons. The agent keeps
/// draining while it sits there.
@MainActor
final class StyleHintWindow: NSObject {
    /// Held for the window's lifetime; released when it closes.
    private static var current: StyleHintWindow?

    private let window: NSWindow
    private let settingsURL: URL?
    private let log: (String) -> Void

    static func show(settingsURL: String, appName: String, log: @escaping (String) -> Void) {
        // Bringing up a second copy would just stack windows.
        if let existing = current {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        current = StyleHintWindow(settingsURL: settingsURL, appName: appName, log: log)
        current?.present()
    }

    private init(settingsURL: String, appName: String, log: @escaping (String) -> Void) {
        self.settingsURL = URL(string: settingsURL)
        self.log = log

        let width: CGFloat = 460
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.isReleasedWhenClosed = false
        window.level = .floating

        super.init()

        let heading = NSTextField(labelWithString: "Keep notifications on screen")
        heading.font = .boldSystemFont(ofSize: 14)

        let body = NSTextField(
            wrappingLabelWithString: """
                macOS shows this app's notifications as Temporary, so they slide away after \
                about five seconds — and clicking a notification is how you jump back to the \
                Claude or Codex session's tab.

                Set Alert Style to Persistent and they wait for you instead.

                Apps cannot change this themselves; only you can. (On older macOS the two \
                choices are called Banners and Alerts.)
                """)
        body.font = .systemFont(ofSize: 12)

        let openButton = NSButton(
            title: "Open Settings", target: self, action: #selector(openSettings))
        openButton.keyEquivalent = "\r"
        let laterButton = NSButton(title: "Not now", target: self, action: #selector(dismiss))

        let buttons = NSStackView(views: [laterButton, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [heading, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: width - 40),
        ])
        window.contentView = content
        window.setContentSize(stack.fittingSize)
    }

    private func present() {
        window.center()
        // An accessory app has nothing of its own in front, so claim activation
        // or the window opens behind whatever the user is doing.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
            log("style guidance: opened settings")
        }
        close()
    }

    @objc private func dismiss() {
        log("style guidance: dismissed")
        close()
    }

    private func close() {
        window.orderOut(nil)
        Self.current = nil
    }
}
