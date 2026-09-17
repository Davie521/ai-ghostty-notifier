import AppKit
import Foundation
import NotifyCore

/// Apple Events to Ghostty, sent in-process — no `osascript` fork, which is the
/// whole reason the polling loop moved into a resident app.
///
/// Read-only sends run on a dedicated serial queue. Focus runs on the main
/// queue with a bounded Apple Event timeout because it pumps WindowServer
/// callbacks that assert main-queue affinity. Each send owns its script;
/// `executeAndReturnError` blocks until the round-trip completes, which for the
/// *first* event means blocking until the user answers the modal
/// "wants to control Ghostty" consent prompt. On the main actor that would wedge
/// the spool drain, the notification posting and the activation observer behind
/// a dialog the user may not notice for minutes.
///
/// Results come back on the main actor. A nil result always means "don't know"
/// — Ghostty may not be running, may not be scriptable, or consent may have been
/// denied — never "no".
///
/// Reaching Ghostty at all requires NSAppleEventsUsageDescription in the app
/// bundle's Info.plist; without it macOS denies the event instead of prompting.
enum Ghostty {
    private static let queue = DispatchQueue(
        label: "com.ghostty-notify.applescript", qos: .userInitiated)

    /// Tab the user is looking at right now.
    ///
    /// Tab granularity, not surface granularity, on purpose: this has to compare
    /// equal to the id `ghostty-tab-save.sh` persists, which is `id of tab`.
    static func selectedTabID(_ completion: @escaping @MainActor (String?) -> Void) {
        run(
            """
            tell application "Ghostty"
                return id of selected tab of front window
            end tell
            """
        ) { value in
            completion(value.flatMap { isPlausibleTabID($0) ? $0 : nil })
        }
    }

    /// Raise the window owning `tabID` and select it.
    ///
    /// Focus the tab's terminal to raise its window too. `activate window`
    /// followed by `select tab` can leave that window behind the current one.
    /// Report the front window's selection so a background selection cannot
    /// masquerade as a successful jump.
    ///
    /// Returning the resulting selection rather than a bare "ok" is deliberate:
    /// the script can succeed while the selection does not stick, and a boolean
    /// cannot tell those apart. It also makes the log self-verifying, which
    /// matters because reading the selection from a separate process a moment
    /// later races the user's own tab switching.
    static func focus(tabID: String, _ completion: @escaping @MainActor (String?) -> Void) {
        // The id comes from persisted state and is interpolated into script
        // source, so a crafted value could otherwise smuggle in `do shell
        // script`. Whitelist first, then escape — either alone would do, but
        // this is the one place where being wrong runs arbitrary code.
        guard isPlausibleTabID(tabID) else {
            Task { @MainActor in completion(nil) }
            return
        }
        let literal = appleScriptLiteral(tabID)
        // A single terminal-focus command keeps selection and window ordering
        // together. Selecting first can change what a live tab reference names.
        run(
            """
            tell application "Ghostty"
                repeat with w in every window
                    repeat with t in every tab of w
                        try
                            if (id of t as text) is \(literal) then
                                focus (focused terminal of t)
                                return (id of selected tab of front window as text)
                            end if
                        end try
                    end repeat
                end repeat
                return ""
            end tell
            """, onMainThread: true
        ) { selected in
            if let paths = try? AgentPaths(env: ProcessInfo.processInfo.environment) {
                AgentLog.append(
                    "focus result: requested=\(tabID) selected=\(selected ?? "<none>")",
                    to: paths.log)
            }
            completion(selected)
        }
    }

    /// Degraded fallback for a click we cannot localize: at least put Ghostty in
    /// front so the user is one keystroke from their session.
    @MainActor
    static func activate() {
        // NSRunningApplication, not an Apple Event: `tell application … to
        // activate` sent from a background process is dropped without an error,
        // which is what made a notification click select the right tab inside a
        // window that never came to the front.
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: AgentConstants.ghosttyBundleID)
        running.first?.activate(options: [.activateAllWindows])
    }

    /// Shape check on a tab id before it is interpolated into script source.
    ///
    /// Ghostty's ids are not UUIDs — a real one looks like `tab-cb7cc1a00`. An
    /// earlier version of this only allowed hex digits and dashes, which
    /// rejected every genuine id (`t` is not hex) and silently disabled both
    /// withdrawal-by-tab and click-to-jump. So: alphanumerics, dash and
    /// underscore, with a length cap. That admits no quote, no backslash, no
    /// newline and no space, which is what keeps `do shell script` out; the
    /// escaping in appleScriptLiteral is the second layer.
    static func isPlausibleTabID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
    }

    static func appleScriptLiteral(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func run(
        _ source: String, onMainThread: Bool = false,
        _ completion: @escaping @MainActor (String?) -> Void
    ) {
        // Focusing pumps WindowServer events, which require the main queue.
        // Read-only queries stay off it so an Automation prompt cannot stall
        // resident spool consumption.
        let executionQueue = onMainThread ? DispatchQueue.main : queue
        executionQueue.async {
            var result: String?
            let bounded =
                onMainThread ? "with timeout of 3 seconds\n\(source)\nend timeout" : source
            if let script = NSAppleScript(source: bounded) {
                var errorInfo: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorInfo)
                if errorInfo == nil, let value = descriptor.stringValue, !value.isEmpty {
                    result = value
                }
            }
            Task { @MainActor in completion(result) }
        }
    }
}
