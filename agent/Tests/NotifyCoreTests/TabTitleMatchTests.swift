import Foundation
import Testing

@testable import NotifyCore

/// A session no marker has bound is found by its title, when exactly one tab
/// carries it.
@Suite struct TabTitleMatchTests {
    static let tabs = [
        // Codex at work: a spinner in front, the folder after " | ".
        TerminalTab(id: "tab-codex", title: "⠙ 运行 Ghostty 通知测试命令 | Desktop"),
        // Claude Code: a status glyph in front.
        TerminalTab(id: "tab-claude", title: "◐ AI Ghosty Notifier 的 Claude Hook"),
        // Ghostty's bell in front of the status glyph.
        TerminalTab(id: "tab-bell", title: "🔔 ✳ iPad mini 7 闲鱼监控"),
        TerminalTab(id: "tab-shell", title: "👻"),
    ]

    @Test func aCodexSessionIsFoundByItsThreadName() {
        #expect(TabTitleMatch.tab(titled: "运行 Ghostty 通知测试命令", among: Self.tabs) == "tab-codex")
    }

    @Test func theSpinnerMayBeAnyFrameOrNone() {
        for title in [
            "⠋ 运行 Ghostty 通知测试命令 | Desktop", "运行 Ghostty 通知测试命令 | Desktop",
            "运行 Ghostty 通知测试命令",
        ] {
            #expect(
                TabTitleMatch.tab(
                    titled: "运行 Ghostty 通知测试命令",
                    among: [TerminalTab(id: "t", title: title)]) == "t")
        }
    }

    @Test func claudeAndBelledTabsToo() {
        #expect(
            TabTitleMatch.tab(titled: "AI Ghosty Notifier 的 Claude Hook", among: Self.tabs)
                == "tab-claude")
        #expect(TabTitleMatch.tab(titled: "iPad mini 7 闲鱼监控", among: Self.tabs) == "tab-bell")
    }

    /// Two sessions with one name are not told apart by guessing.
    @Test func moreThanOneMatchIsNoMatch() {
        let twins = Self.tabs + [TerminalTab(id: "tab-twin", title: "⠹ 运行 Ghostty 通知测试命令 | src")]
        #expect(TabTitleMatch.tab(titled: "运行 Ghostty 通知测试命令", among: twins) == nil)
    }

    @Test func onlyTheWholeNameCounts() {
        // A title that merely starts the same is another session.
        #expect(TabTitleMatch.tab(titled: "运行 Ghostty", among: Self.tabs) == nil)
        #expect(TabTitleMatch.tab(titled: "Claude Hook", among: Self.tabs) == nil)
        #expect(TabTitleMatch.tab(titled: "", among: Self.tabs) == nil)
        #expect(TabTitleMatch.tab(titled: "a", among: [TerminalTab(id: "t", title: "a")]) == nil)
        #expect(TabTitleMatch.tab(titled: "nothing like it", among: Self.tabs) == nil)
    }

    /// A name may begin with a glyph of its own; both sides lose it alike.
    @Test func aNameThatStartsWithAnEmojiStillMatches() {
        let tabs = [TerminalTab(id: "t", title: "⠙ 🚀 Release | repo")]
        #expect(TabTitleMatch.tab(titled: "🚀 Release", among: tabs) == "t")
        #expect(TabTitleMatch.tab(titled: "Release", among: tabs) == "t")
        #expect(TabTitleMatch.tab(titled: "🚀", among: tabs) == nil)
    }

    @Test func spacingDoesNotMatter() {
        #expect(
            TabTitleMatch.tab(
                titled: "  运行  Ghostty 通知测试命令 ",
                among: [TerminalTab(id: "t", title: "⠙  运行 Ghostty  通知测试命令 | Desktop")]) == "t")
    }

    @Test func theNudgeCarriesTheTitleThroughTheSpool() throws {
        var request = NotifyRequest(sessionID: "01a1978b-a857", title: "Codex", source: .codex)
        request.tabTitle = "运行 Ghostty 通知测试命令"
        #expect(try RequestCodec.decode(RequestCodec.encode(.notify(request))) == .notify(request))
        let plain = NotifyRequest(sessionID: "01a1978b-a857", title: "Codex", source: .codex)
        let encoded = try RequestCodec.encode(.notify(plain))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("tab_title"))
    }

    @Test func theReportSaysTheTabIsLookedFor() {
        let report = NudgeNotification.sent(tabKnown: false, lookedUp: true)
        #expect(report.contains("titled after the session"))
        #expect(
            NudgeNotification.sent(tabKnown: true, lookedUp: true).contains("this session's tab"))
    }
}
