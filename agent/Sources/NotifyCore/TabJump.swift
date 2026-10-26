import Foundation

/// The steps of one click-to-jump, decided from what Ghostty and the window
/// server report back.
///
/// Ghostty's `focus` orders the tab's window front and activates Ghostty.
/// When that window is on a Space out of view, macOS switches to its Space
/// only if Ghostty has no window on any Space in view; otherwise the window
/// is brought onto the current Space, which is issue #63. So a jump first
/// locates the tab's window and, when the window is out of view, travels to
/// its Space with the user's own shortcut before focusing. Travel needs the
/// Accessibility permission and can fail; every such failure falls through to
/// the plain focus, which is what the jump did before and still better than
/// nothing.
///
/// Focusing a tab and reading which tab is selected are two Apple Events, and
/// the read can land before Ghostty has finished the focus: the reply then
/// names the tab the user was on when they clicked, and the jump looks as if
/// it never happened although it did (issue #40, both samples). So a mismatch
/// is not a verdict. It earns one re-read after a short settle, and if the
/// selection still has not moved, one more focus command; only after that
/// does the jump give up. Every count is bounded, so a Ghostty that never
/// answers the way we hope cannot keep this going.
///
/// Pure bookkeeping, no Apple Events and no window server: the resident
/// drives it and NotifyCore tests can walk every path.
public struct TabJump: Equatable, Sendable {
    /// What the read-only lookup of the requested tab found.
    public enum Probe: Equatable, Sendable {
        /// The id of the window (tab group) holding the requested tab.
        case found(window: String)
        /// No window has a tab with that id.
        case notFound
        /// The lookup got no answer. Not a verdict either way.
        case unknown
    }

    /// How a trip to a hidden window's Space ended.
    public enum HopResult: Equatable, Sendable {
        /// The Space came into view.
        case arrived
        /// It did not get there, and the desktops are as they were; `reason`
        /// is for the log.
        case failed(reason: String)
        /// It did not get there, and could not put the desktops back.
        case stranded(reason: String)
    }

    public enum Outcome: Equatable, Sendable {
        /// The requested tab is selected. `reads` is how many settle re-reads
        /// it took; `focusAttempts` how many focus commands.
        case verified(reads: Int, focusAttempts: Int)
        /// Ghostty found no tab with that id.
        case notFound
        /// After every allowed attempt, some other tab is still selected.
        case unverified(selected: String?, focusAttempts: Int)
        /// Given up where it stood because the app is quitting or the work was
        /// cancelled. Nothing after that was done, the focus included: a focus
        /// without the trip before it is what pulled windows across Spaces.
        case abandoned
        /// A trip stopped part-way and could not get back. Nothing was
        /// focused: a focus now would bring the window to wherever the
        /// desktops were left, a Space the user never chose.
        case strandedTrip
    }

    public enum Step: Equatable, Sendable {
        /// Ask Ghostty, changing nothing, which window holds the tab. At the
        /// start, and again after a trip: whether the window is now in view
        /// is decided from what Ghostty and the window server say then, not
        /// from titles read before the trip, which a busy session will have
        /// changed by the time it ends.
        case locate
        /// Ask the window server and Accessibility where that window is.
        case survey(window: String)
        /// Travel to the Space of this window.
        case hop(OrderedWindow)
        /// Send the focus command.
        case focus
        /// Read the selected tab again after this many seconds.
        case verify(after: Double)
        case stop(Outcome)
    }

    /// How long Ghostty is given to finish a focus before the selection is
    /// read again. The samples in issue #40 show the read arriving in the same
    /// second as the focus; this is well past that.
    public static let settleSeconds = 0.2
    /// Focus commands per jump, in total.
    public static let maxFocusAttempts = 2
    /// Trips per jump, in total. A second one happens only when a fresh
    /// look after the first still finds the window out of view.
    public static let maxHops = 2
    /// Fresh reads per jump after a survey whose lists did not pair. Past
    /// this the jump focuses without travelling, as it did before trips.
    public static let maxRereads = 2

    public let requested: String
    public private(set) var focusAttempts = 0
    public private(set) var reads = 0
    /// The window holding the requested tab, once located.
    public private(set) var window: String?
    public private(set) var hops = 0
    public private(set) var rereads = 0
    public private(set) var lastHop: HopResult?
    /// Windows the last survey placed out of view, most likely first.
    private var candidates: [OrderedWindow] = []
    /// Windows already travelled to; a later survey does not send the jump
    /// back to one of them.
    private var visited: Set<UInt32> = []
    /// Re-reads since the last focus command; one is allowed per focus.
    private var readsSinceFocus = 0

    public init(requested: String) {
        self.requested = requested
    }

    /// The first step of every jump.
    public var start: Step { .locate }

    /// The jump is to stop where it stands: the app is quitting. Whatever step
    /// was next is not taken.
    public func abandon() -> Step { .stop(.abandoned) }

    /// What the lookup found.
    public mutating func observe(probe: Probe) -> Step {
        switch probe {
        case .found(let window):
            self.window = window
            return .survey(window: window)
        case .notFound:
            return .stop(.notFound)
        case .unknown:
            // The focus command answers for itself, as it did before lookups.
            return .focus
        }
    }

    /// Where the survey placed the window.
    public mutating func observe(place: WindowPlace) -> Step {
        switch place {
        case .showing, .unknown:
            return .focus
        case .unsettled:
            guard rereads < Self.maxRereads else { return .focus }
            rereads += 1
            return .locate
        case .hidden(let candidates):
            self.candidates = candidates
            return nextHop() ?? .focus
        }
    }

    /// How the trip ended.
    public mutating func observe(hopResult: HopResult) -> Step {
        lastHop = hopResult
        switch hopResult {
        case .arrived: return .locate
        case .failed: return .focus
        case .stranded: return .stop(.strandedTrip)
        }
    }

    private mutating func nextHop() -> Step? {
        guard hops < Self.maxHops,
            let next = candidates.first(where: { !visited.contains($0.number) })
        else { return nil }
        hops += 1
        visited.insert(next.number)
        return .hop(next)
    }

    /// What the focus command reported as the selection of the front window,
    /// or nil when the tab was not found or the command failed.
    public mutating func observe(focusResult selected: String?) -> Step {
        focusAttempts += 1
        readsSinceFocus = 0
        guard let selected else { return .stop(.notFound) }
        if selected == requested {
            return .stop(.verified(reads: reads, focusAttempts: focusAttempts))
        }
        return .verify(after: Self.settleSeconds)
    }

    /// What a standalone selection read returned.
    public mutating func observe(selected: String?) -> Step {
        reads += 1
        readsSinceFocus += 1
        if selected == requested {
            return .stop(.verified(reads: reads, focusAttempts: focusAttempts))
        }
        if focusAttempts < Self.maxFocusAttempts { return .focus }
        return .stop(.unverified(selected: selected, focusAttempts: focusAttempts))
    }
}
