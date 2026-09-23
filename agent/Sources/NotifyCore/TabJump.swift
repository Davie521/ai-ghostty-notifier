import Foundation

/// The steps of one click-to-jump, decided from what Ghostty reports back.
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
/// Pure bookkeeping, no Apple Events: the resident drives it and NotifyCore
/// tests can walk every path.
public struct TabJump: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The requested tab is selected. `reads` is how many settle re-reads
        /// it took; `focusAttempts` how many focus commands.
        case verified(reads: Int, focusAttempts: Int)
        /// Ghostty found no tab with that id.
        case notFound
        /// After every allowed attempt, some other tab is still selected.
        case unverified(selected: String?, focusAttempts: Int)
    }

    public enum Step: Equatable, Sendable {
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

    public let requested: String
    public private(set) var focusAttempts = 0
    public private(set) var reads = 0
    /// Re-reads since the last focus command; one is allowed per focus.
    private var readsSinceFocus = 0

    public init(requested: String) {
        self.requested = requested
    }

    /// The first step of every jump.
    public var start: Step { .focus }

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
