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

    /// The lists differ in length (a window opening, say): no pairing is
    /// trusted and nothing is concluded; a fresh read decides.
    @Test func listsOfDifferentLengthsAreUnsettled() {
        let ordered = [
            OrderedWindow(number: 1, spaces: [10]), OrderedWindow(number: 2, spaces: [8]),
            OrderedWindow(number: 3, spaces: [1773]),
        ]
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .unsettled)
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

    /// A title Accessibility shows on another window than the order says
    /// means the order is off, or a title changed between the two reads.
    @Test func aPairingTheTitlesContradictIsUnsettled() {
        let scripted = [
            ScriptedWindow(id: "tab-group-a", title: "alpha"),
            ScriptedWindow(id: "tab-group-b", title: "beta"),
        ]
        let ordered = [
            OrderedWindow(number: 1, spaces: [10]), OrderedWindow(number: 2, spaces: [8]),
        ]
        let seen = [SeenWindow(number: 1, title: "beta")]
        for id in ["tab-group-a", "tab-group-b"] {
            #expect(
                WindowPlace.of(
                    id, scripted: scripted, ordered: ordered, seen: seen, visibleSpaces: visible)
                    == .unsettled)
        }
    }

    /// The window in view retitled itself between the two reads, as a busy
    /// session does twice a second. Taking the missing old title for "out of
    /// view" would switch a display for nothing.
    @Test func aVisibleWindowWhoseTitleJustChangedIsNotTakenForHidden() {
        let retitled = [SeenWindow(number: 224_461, title: "✶ backend")]
        #expect(
            WindowPlace.of(
                "tab-group-a", scripted: scripted, ordered: ordered, seen: retitled,
                visibleSpaces: visible) == .unsettled)
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

    /// Untitled windows still pair by order.
    @Test func untitledWindowsPairByOrder() {
        let scripted = [ScriptedWindow(id: "tab-group-a", title: "")]
        let seen = [SeenWindow(number: 1, title: "")]
        let ordered = [OrderedWindow(number: 1, spaces: [8])]
        #expect(
            WindowPlace.of(
                "tab-group-a", scripted: scripted, ordered: ordered, seen: seen,
                visibleSpaces: visible) == .hidden(candidates: ordered))
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

    /// Without Accessibility, lists of different lengths settle nothing either.
    @Test func withoutAccessibilityListsOfDifferentLengthsAreUnsettled() {
        let ordered = [
            OrderedWindow(number: 1, spaces: [10]), OrderedWindow(number: 2, spaces: [8]),
            OrderedWindow(number: 3, spaces: [5]),
        ]
        #expect(
            WindowPlace.of(
                "tab-group-b", scripted: scripted, ordered: ordered, seen: nil,
                visibleSpaces: visible) == .unsettled)
    }

    /// A window or tab that could not be read on the way: the tab may be the
    /// one, so the reply is "don't know", not "not there".
    @Test func anIncompleteLocateIsUnknown() {
        let (probe, windows) = ScriptedWindow.locateReply("?\u{1E}tab-group-a\u{1F}zsh\u{1E}")
        #expect(probe == .unknown)
        #expect(windows == [ScriptedWindow(id: "tab-group-a", title: "zsh")])
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
}
