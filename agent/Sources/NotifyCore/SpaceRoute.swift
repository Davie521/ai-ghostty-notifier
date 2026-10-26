import Foundation

/// The Spaces each display offers and the one it shows, as the window server
/// reports them. Pure data, so the way to a Space is testable without one.
public struct SpaceTopology: Equatable, Sendable {
    public struct Display: Equatable, Sendable {
        /// The window server's name for the display, a UUID string.
        public let identifier: String
        /// This display's Spaces in the order the user arranged them, which is
        /// the order the "move left/right a space" shortcuts walk.
        public let spaces: [UInt64]
        /// The Space this display shows right now.
        public let current: UInt64?

        public init(identifier: String, spaces: [UInt64], current: UInt64?) {
            self.identifier = identifier
            self.spaces = spaces
            self.current = current
        }
    }

    public let displays: [Display]

    public init(displays: [Display]) {
        self.displays = displays
    }

    /// The Spaces showing on some display.
    public var visibleSpaces: Set<UInt64> { Set(displays.compactMap(\.current)) }

    /// Whether a window on these Spaces is in view on some display.
    public func shows(anyOf spaces: [UInt64]) -> Bool {
        spaces.contains { visibleSpaces.contains($0) }
    }
}

/// One stretch of travel to a Space: the shortcut pressed `steps` times
/// towards `direction` while `display` is the one the shortcut acts on.
public struct SpaceHop: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case left
        case right
    }

    public let display: String
    public let direction: Direction
    public let steps: Int
    /// The Space one press should bring into view.
    public let next: UInt64

    public init(display: String, direction: Direction, steps: Int, next: UInt64) {
        self.display = display
        self.direction = direction
        self.steps = steps
        self.next = next
    }
}

/// How to bring a Space into view, read off the topology.
///
/// macOS switches Spaces for a click only when the app that is activated has
/// no window on any Space in view. Ghostty usually has one — the window the
/// user was just working in, often on the other display — and then the
/// click's focus pulls the session's window onto the current Space instead
/// (issue #63). Walking there with the user's own "move a space" shortcut is
/// what the system does allow, and this is the walk: which display, which
/// way, how many presses. Recomputed after every press, so a Mission Control
/// that rearranges Spaces by recent use cannot send the walk the wrong way.
public enum SpaceRoute: Equatable, Sendable {
    /// Already in view on some display.
    case showing
    case hop(SpaceHop)
    /// On no display, or further than a click should carry the user.
    case unreachable

    /// The most presses one jump makes.
    public static let maxSteps = 16

    public static func to(_ target: UInt64, in topology: SpaceTopology) -> SpaceRoute {
        for display in topology.displays {
            guard let targetIndex = display.spaces.firstIndex(of: target) else { continue }
            guard let current = display.current else { return .unreachable }
            if current == target { return .showing }
            guard let currentIndex = display.spaces.firstIndex(of: current) else {
                return .unreachable
            }
            let steps = abs(targetIndex - currentIndex)
            guard steps <= maxSteps else { return .unreachable }
            let direction: SpaceHop.Direction = targetIndex > currentIndex ? .right : .left
            let next = display.spaces[direction == .right ? currentIndex + 1 : currentIndex - 1]
            return .hop(
                SpaceHop(
                    display: display.identifier, direction: direction, steps: steps, next: next)
            )
        }
        return .unreachable
    }
}
