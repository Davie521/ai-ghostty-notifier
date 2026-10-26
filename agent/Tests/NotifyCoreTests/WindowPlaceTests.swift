import Testing

@testable import NotifyCore

@Suite struct WindowPlaceTests {
    let visible: Set<UInt64> = [6, 10]
    // Front to back: the window the user works in, on a visible Space, and
    // one on a hidden Space of the other display.
    let scripted = [
        ScriptedWindow(id: "tab-group-a", title: "✳ backend"),
        ScriptedWindow(id: "tab-group-b", title: "yifan@mac:~"),
    ]
    let ordered = [
        OrderedWindow(number: 224_461, spaces: [10]), OrderedWindow(number: 221_248, spaces: [8]),
    ]
    let seen = [SeenWindow(number: 224_461, title: "✳ backend")]

    @Test func aWindowAccessibilitySeesIsShowing() {
        #expect(
            WindowPlace.of(
                "tab-group-a", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .showing)
    }

    @Test func theOneHiddenWindowIsTheOneOutOfView() {
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .hidden(candidates: [ordered[1]]))
    }

    @Test func aWindowTheListingLacksIsUnknown() {
        #expect(
            WindowPlace.of(
                "tab-group-zzz", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .unknown)
    }

    /// Two hidden windows: the order pairs them, so the jump tries the right
    /// one first and keeps the other in case the pairing was off.
    @Test func hiddenWindowsArePairedByOrderWhenTheCountsAgree() {
        let scripted = [
            ScriptedWindow(id: "tab-group-a", title: "✳ backend"),
            ScriptedWindow(id: "tab-group-b", title: "one"),
            ScriptedWindow(id: "tab-group-c", title: "two"),
        ]
        let ordered = [
            OrderedWindow(number: 1, spaces: [10]), OrderedWindow(number: 2, spaces: [8]),
            OrderedWindow(number: 3, spaces: [1773]),
        ]
        #expect(
            WindowPlace.of(
                "tab-group-c", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .hidden(candidates: [ordered[2], ordered[1]]))
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .hidden(candidates: [ordered[1], ordered[2]]))
    }

    /// The counts disagree (a window mid-creation, say): no pairing is
    /// trusted, every hidden window stays a candidate in order.
    @Test func hiddenWindowsAllStayCandidatesWhenTheCountsDisagree() {
        let ordered = [
            OrderedWindow(number: 1, spaces: [10]), OrderedWindow(number: 2, spaces: [8]),
            OrderedWindow(number: 3, spaces: [1773]),
        ]
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .hidden(candidates: [ordered[1], ordered[2]]))
    }

    /// Two windows titled alike, one in view: the title is counted, so the
    /// hidden one is not passed off as showing.
    @Test func aDuplicateTitleDoesNotHideAHiddenWindow() {
        let scripted = [
            ScriptedWindow(id: "tab-group-a", title: "zsh"),
            ScriptedWindow(id: "tab-group-b", title: "zsh"),
        ]
        let seen = [SeenWindow(number: 224_461, title: "zsh")]
        #expect(
            WindowPlace.of(
                "tab-group-a", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .showing)
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .hidden(candidates: [ordered[1]]))
    }

    /// Nothing of Ghostty's is on a hidden Space: whatever the titles say,
    /// there is nowhere to travel.
    @Test func noHiddenWindowMeansShowing() {
        let ordered = [OrderedWindow(number: 224_461, spaces: [10])]
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: [],
                visibleSpaces: visible) == .showing)
    }

    /// Ordered windows the window server puts on no Space are leftovers, not
    /// candidates.
    @Test func windowsOnNoSpaceAreNotCandidates() {
        let ordered = [
            OrderedWindow(number: 224_461, spaces: [10]), OrderedWindow(number: 5, spaces: []),
            OrderedWindow(number: 221_248, spaces: [8]),
        ]
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .hidden(candidates: [ordered[2]]))
    }

    @Test func anEmptyTitleNeverMatches() {
        let scripted = [ScriptedWindow(id: "tab-group-a", title: "")]
        let seen = [SeenWindow(number: 1, title: "")]
        let ordered = [OrderedWindow(number: 1, spaces: [8])]
        #expect(
            WindowPlace.of(
                "tab-group-a", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .hidden(candidates: ordered))
    }
}
