import AppKit
import ApplicationServices
import NotifyCore

/// What a jump needs that neither Apple Events nor Accessibility can tell it:
/// which Space each of Ghostty's windows is on, which Spaces each display
/// shows, and which keys the user has set for moving between them.
///
/// Spaces have no public API. The window-server calls below are looked up by
/// name at run time — the same ones the window switchers and tiling managers
/// use — and a macOS that drops one leaves the matching answer nil, which a
/// jump treats as "no travel" and falls back to the plain focus; it never
/// keeps the app from launching.
///
/// Everything here runs on the main actor: the Accessibility reads and the
/// event posts are short, and the jump is already there.
@MainActor
enum WindowServer {
    private typealias ConnectionID = Int32
    private typealias MainConnection = @convention(c) () -> ConnectionID
    private typealias CopySpacesForWindows =
        @convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpaces =
        @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    private typealias WindowIsOrderedIn =
        @convention(c) (ConnectionID, CGWindowID, UnsafeMutablePointer<Bool>) -> CGError
    private typealias SymbolicHotKeyValue =
        @convention(c) (
            Int32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>,
            UnsafeMutablePointer<UInt32>
        ) -> CGError
    private typealias SymbolicHotKeyEnabled = @convention(c) (Int32) -> Bool
    private typealias ElementWindowNumber =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let everything = dlopen(nil, RTLD_NOW)

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?, _: T.Type)
        -> T?
    {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let connection: ConnectionID =
        symbol("CGSMainConnectionID", in: skyLight, MainConnection.self)?() ?? 0
    private static let copySpacesForWindows = symbol(
        "CGSCopySpacesForWindows", in: skyLight, CopySpacesForWindows.self)
    private static let copyManagedDisplaySpaces = symbol(
        "CGSCopyManagedDisplaySpaces", in: skyLight, CopyManagedDisplaySpaces.self)
    private static let windowIsOrderedIn = symbol(
        "CGSWindowIsOrderedIn", in: skyLight, WindowIsOrderedIn.self)
    private static let symbolicHotKeyValue = symbol(
        "CGSGetSymbolicHotKeyValue", in: skyLight, SymbolicHotKeyValue.self)
    private static let symbolicHotKeyEnabled = symbol(
        "CGSIsSymbolicHotKeyEnabled", in: skyLight, SymbolicHotKeyEnabled.self)
    private static let elementWindowNumber = symbol(
        "_AXUIElementGetWindow", in: everything, ElementWindowNumber.self)

    // MARK: - Spaces

    /// The Spaces a window sits on. Empty for a window on none, which is what
    /// the window server says of a window that is ordered out.
    static func spaces(of window: CGWindowID) -> [UInt64] {
        guard connection != 0, let copySpacesForWindows else { return [] }
        let mask: Int32 = 0x7  // every kind of Space: user, fullscreen, system
        guard
            let array = copySpacesForWindows(
                connection, mask, [NSNumber(value: window)] as CFArray)?
                .takeRetainedValue() as? [NSNumber]
        else { return [] }
        return array.map(\.uint64Value)
    }

    /// Each display's Spaces in order and the one it shows. Nil when the
    /// window server does not answer, which no jump should mistake for an
    /// empty desktop.
    static func topology() -> SpaceTopology? {
        guard connection != 0, let copyManagedDisplaySpaces,
            let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue()
                as? [[String: Any]]
        else { return nil }
        let parsed = displays.compactMap { display -> SpaceTopology.Display? in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            let spaces = (display["Spaces"] as? [[String: Any]] ?? [])
                .compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            let current = ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?
                .uint64Value
            guard !spaces.isEmpty else { return nil }
            return SpaceTopology.Display(identifier: identifier, spaces: spaces, current: current)
        }
        return parsed.isEmpty ? nil : SpaceTopology(displays: parsed)
    }

    /// Nil when the question cannot be asked.
    private static func isOrderedIn(_ window: CGWindowID) -> Bool? {
        guard connection != 0, let windowIsOrderedIn else { return nil }
        var ordered = false
        guard windowIsOrderedIn(connection, window, &ordered) == .success else { return nil }
        return ordered
    }

    // MARK: - Ghostty's windows

    /// The window's frame in the global coordinates pointer events use, as
    /// the window server has it. Nil for a window it no longer knows.
    static func bounds(of window: CGWindowID) -> CGRect? {
        let info =
            CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]] ?? []
        guard let entry = info.first, let raw = entry[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: raw)
        else { return nil }
        return bounds
    }

    /// Ghostty's windows the window server has ordered in, front to back, on
    /// every Space, at every level: "Float on Top" and the quick terminal put
    /// terminals above the ordinary level. Windows that are not terminals —
    /// an About box, an open menu — come along; `WindowPlace` sets those aside. One per tab group: a native tab that is not the
    /// selected one is an ordered-out window. Closed tabs leave windows behind
    /// that still name a Space for a while; the ordering question tells those
    /// apart, so they are left out when it can be asked.
    static func orderedWindows(ownedBy pid: pid_t) -> [OrderedWindow] {
        let info =
            CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var owned = Set<CGWindowID>()
        for entry in info {
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue, layer >= 0,
                let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            owned.insert(number)
        }
        let frontToBack = NSWindow.windowNumbers(options: [.allApplications, .allSpaces]) ?? []
        return frontToBack.compactMap { value -> OrderedWindow? in
            let number = value.uint32Value
            guard owned.contains(number), isOrderedIn(number) != false else { return nil }
            return OrderedWindow(number: number, spaces: spaces(of: number))
        }
    }

    /// Ghostty's windows as Accessibility lists them — those on Spaces in
    /// view — with their titles. Empty without the Accessibility permission.
    static func seenWindows(ownedBy pid: pid_t) -> [SeenWindow] {
        guard isTrusted, let elementWindowNumber else { return [] }
        let application = AXUIElementCreateApplication(pid)
        // A Ghostty that is busy must not hold the click for long.
        AXUIElementSetMessagingTimeout(application, 1)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
                == .success, let windows = value as? [AXUIElement]
        else { return [] }
        var seen: [SeenWindow] = []
        for element in windows {
            // A timeout set on the application does not carry over to the
            // window elements it returns.
            AXUIElementSetMessagingTimeout(element, 1)
            var number: CGWindowID = 0
            guard elementWindowNumber(element, &number) == .success else { continue }
            var title: CFTypeRef?
            let read = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            // A Ghostty that stopped answering will not answer the next one either.
            if read == .cannotComplete { break }
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
            seen.append(
                SeenWindow(
                    number: number, title: title as? String ?? "",
                    minimized: (minimized as? Bool) ?? false))
        }
        return seen
    }

    // MARK: - Accessibility

    /// Whether this process may read other apps' windows and post key events.
    /// The permission is granted to the app bundle in System Settings; it is
    /// what a trip to another Space needs and nothing else here does.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Has macOS show its own "wants to control this computer" dialog, which
    /// leads to the setting. Nothing comes back: the user answers in System
    /// Settings, in their own time.
    static func askForTrust() {
        // The key by name: the framework's global for it is not concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static let accessibilitySettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    // MARK: - The user's "move a space" shortcut

    struct Shortcut: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    /// The keys macOS has registered for moving one Space over, as the user
    /// set them. Nil when the shortcut is switched off or unreadable: then
    /// there is nothing to press.
    static func shortcut(_ direction: SpaceHop.Direction) -> Shortcut? {
        guard let symbolicHotKeyEnabled, let symbolicHotKeyValue else { return nil }
        // macOS's ids for "Move left a space" and "Move right a space".
        let id: Int32 = direction == .left ? 79 : 81
        guard symbolicHotKeyEnabled(id) else { return nil }
        var character: UInt32 = 0
        var keyCode: UInt32 = 0
        var modifiers: UInt32 = 0
        guard symbolicHotKeyValue(id, &character, &keyCode, &modifiers) == .success,
            keyCode <= UInt32(UInt16.max)
        else { return nil }
        // The modifiers come in the event-flag layout, Fn bit for arrows included.
        return Shortcut(
            keyCode: CGKeyCode(keyCode), flags: CGEventFlags(rawValue: UInt64(modifiers)))
    }

    /// One press, as the keyboard would send it. Dropped by macOS without the
    /// Accessibility permission.
    ///
    /// The key up carries only the modifiers the user is physically holding.
    /// The system takes its modifier state from the last key event of this
    /// source, so a key up that still carried Control would leave Control
    /// held: every click after the jump would arrive as a Control-click until
    /// the next key press (seen in another tool: openclaw/Peekaboo#797).
    static func press(_ shortcut: Shortcut) {
        let modifiers: CGEventFlags = [
            .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn,
        ]
        let held = CGEventSource.flagsState(.hidSystemState).intersection(modifiers)
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(
                keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
            let up = CGEvent(
                keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false)
        else { return }
        // Down, exactly the registered chord: a modifier the user happens to
        // hold would make it another shortcut. Up, what is physically held,
        // which puts the system's modifier state back as the user has it.
        down.flags = shortcut.flags
        up.flags = held
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Displays and the pointer

    /// The display's frame in the global coordinates pointer events use.
    /// With "Displays have separate Spaces" off the window server names one
    /// shared set of Spaces "Main"; the shortcut then switches every display,
    /// so the main display does.
    static func displayBounds(_ identifier: String) -> CGRect? {
        if identifier == "Main" { return CGDisplayBounds(CGMainDisplayID()) }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        for display in displays.prefix(Int(count)) {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
                let name = CFUUIDCreateString(nil, uuid) as String?,
                name.caseInsensitiveCompare(identifier) == .orderedSame
            else { continue }
            return CGDisplayBounds(display)
        }
        return nil
    }

    static var pointer: CGPoint? { CGEvent(source: nil)?.location }

    /// Moves the pointer: a warp, which takes effect at once, then the event
    /// a mouse would send, so everything that follows the pointer sees it.
    static func movePointer(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }
}
