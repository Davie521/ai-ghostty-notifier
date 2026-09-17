import AppKit
import Foundation
import NotifyCore

/// The same in-process implementation is used by the resident app and its
/// short-lived hook mode. Structured Apple Event lists preserve title contents.
struct MacTerminalAutomation: TerminalAutomationProviding {
    private static let queue = DispatchQueue(
        label: "ghostty.native-binding.applescript", qos: .utility)
    func processID() async -> pid_t? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: AgentConstants.ghosttyBundleID
        )
        .first?.processIdentifier
    }
    func tabs() async throws -> [TerminalTab] {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                let source = """
                    with timeout of 3 seconds
                        tell application "Ghostty"
                            set entries to {}
                            repeat with w in every window
                                repeat with t in every tab of w
                                    set end of entries to {(id of t as text), (name of t as text)}
                                end repeat
                            end repeat
                            return entries
                        end tell
                    end timeout
                    """
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: CocoaError(.executableRuntimeMismatch))
                    return
                }
                var error: NSDictionary?
                let response = script.executeAndReturnError(&error)
                if let error {
                    continuation.resume(
                        throwing: NSError(
                            domain: "GhosttyAppleEvents",
                            code: (error[NSAppleScript.errorNumber] as? Int) ?? -1,
                            userInfo: [NSLocalizedDescriptionKey: error.description]))
                    return
                }
                var tabs: [TerminalTab] = []
                if response.numberOfItems > 0 {
                    for index in 1...response.numberOfItems {
                        guard let item = response.atIndex(index),
                            let id = item.atIndex(1)?.stringValue,
                            let title = item.atIndex(2)?.stringValue,
                            Ghostty.isPlausibleTabID(id)
                        else { continue }
                        tabs.append(TerminalTab(id: id, title: title))
                    }
                }
                continuation.resume(returning: tabs)
            }
        }
    }
    func focus(tabID: String?) async {
        if let tabID {
            let selected = await withCheckedContinuation { continuation in
                Ghostty.focus(tabID: tabID) { continuation.resume(returning: $0) }
            }
            if selected == tabID { return }
        }
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
            Ghostty.activate()
        }
    }
    func isFrontmost() async -> Bool? {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map {
                $0 == AgentConstants.ghosttyBundleID
            }
        }
    }
    func selectedTabID() async -> String? {
        await withCheckedContinuation { continuation in
            Ghostty.selectedTabID { continuation.resume(returning: $0) }
        }
    }
}
