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

    /// Two windows titled alike, one in view: the order pairs them, so the
    /// hidden one is not passed off as showing, whichever is in front.
    @Test(arguments: [false, true])
    func windowsTitledAlikeArePairedByOrder(hiddenInFront: Bool) {
        let scripted = [
            ScriptedWindow(id: "tab-group-a", title: "zsh"),
            ScriptedWindow(id: "tab-group-b", title: "zsh"),
        ]
        let showingWindow = OrderedWindow(number: 224_461, spaces: [10])
        let hiddenWindow = OrderedWindow(number: 221_248, spaces: [8])
        let ordered =
            hiddenInFront ? [hiddenWindow, showingWindow] : [showingWindow, hiddenWindow]
        let seen = [SeenWindow(number: 224_461, title: "zsh")]
        let front = WindowPlace.of(
            "tab-group-a", scripted: scripted, ordered: ordered, seen: seen,
            visibleSpaces: visible)
        let back = WindowPlace.of(
            "tab-group-b", scripted: scripted, ordered: ordered, seen: seen,
            visibleSpaces: visible)
        #expect(front == (hiddenInFront ? .hidden(candidates: [hiddenWindow]) : .showing))
        #expect(back == (hiddenInFront ? .showing : .hidden(candidates: [hiddenWindow])))
    }

    /// The lists differ in length, so only titles are left, and a title in
    /// view fewer times than it is listed could be either window: no travel.
    @Test func anAmbiguousTitleConcludesNothing() {
        let scripted = [
            ScriptedWindow(id: "tab-group-a", title: "zsh"),
            ScriptedWindow(id: "tab-group-b", title: "zsh"),
        ]
        let ordered = [
            OrderedWindow(number: 1, spaces: [10]), OrderedWindow(number: 2, spaces: [8]),
            OrderedWindow(number: 3, spaces: [5]),
        ]
        let seen = [SeenWindow(number: 1, title: "zsh")]
        #expect(
            WindowPlace.of(
                "tab-group-a", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .unknown)
    }

    /// A title Accessibility shows on another window than the order says
    /// means the order is off; the titles decide instead.
    @Test func aPairingTheTitlesContradictFallsBackToTitles() {
        let scripted = [
            ScriptedWindow(id: "tab-group-a", title: "alpha"),
            ScriptedWindow(id: "tab-group-b", title: "beta"),
        ]
        let ordered = [
            OrderedWindow(number: 1, spaces: [10]), OrderedWindow(number: 2, spaces: [8]),
        ]
        let seen = [SeenWindow(number: 1, title: "beta")]
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .showing)
        #expect(
            WindowPlace.of(
                "tab-group-a", scripted: scripted, ordered: ordered, seen: seen,
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

    /// With only titles to go on, an empty one is never taken as in view.
    @Test func anEmptyTitleNeverMatches() {
        let scripted = [ScriptedWindow(id: "tab-group-a", title: "")]
        let seen = [SeenWindow(number: 9, title: "")]
        let ordered = [
            OrderedWindow(number: 1, spaces: [8]), OrderedWindow(number: 2, spaces: [5]),
        ]
        #expect(
            WindowPlace.of(
                "tab-group-a", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .hidden(candidates: ordered))
    }

    @Test func theLocateReplyNamesTheWindowAndListsTheRest() {
        let reply =
            "tab-group-b\u{1E}tab-group-a\u{1F}✳ backend\u{1E}tab-group-b\u{1F}yifan@mac:~\u{1E}"
        let (probe, windows) = ScriptedWindow.locateReply(reply)
        #expect(probe == .found(window: "tab-group-b"))
        #expect(windows == scripted)
    }

    @Test func aLocateReplyWithNoWindowIdMeansNotFound() {
        let (probe, windows) = ScriptedWindow.locateReply("\u{1E}tab-group-a\u{1F}zsh\u{1E}")
        #expect(probe == .notFound)
        #expect(windows == [ScriptedWindow(id: "tab-group-a", title: "zsh")])
    }

    /// A script that failed is not "no such tab".
    @Test func noLocateReplyIsUnknown() {
        let (probe, windows) = ScriptedWindow.locateReply(nil)
        #expect(probe == .unknown)
        #expect(windows.isEmpty)
    }

    @Test func aTitleMayBeEmpty() {
        let (_, windows) = ScriptedWindow.locateReply("x\u{1E}tab-group-a\u{1F}\u{1E}")
        #expect(windows == [ScriptedWindow(id: "tab-group-a", title: "")])
    }

    /// Without Accessibility the order still places the window: that is how
    /// a jump knows it needed the permission.
    @Test func withoutAccessibilityTheOrderStillPlaces() {
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: nil,
                visibleSpaces: visible) == .hidden(candidates: [ordered[1]]))
        #expect(
            WindowPlace.of(
                "tab-group-a", scripted: scripted, ordered: ordered, seen: nil,
                visibleSpaces: visible) == .showing)
    }

    /// Without Accessibility there are no titles to fall back on.
    @Test func withoutAccessibilityTitlesCannotDecide() {
        let ordered = [
            OrderedWindow(number: 1, spaces: [10]), OrderedWindow(number: 2, spaces: [8]),
            OrderedWindow(number: 3, spaces: [5]),
        ]
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: nil,
                visibleSpaces: visible) == .unknown)
    }
}
