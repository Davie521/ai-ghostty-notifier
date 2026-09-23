import Foundation
import Testing

@testable import NotifyCore

/// The translations live in agent/Resources/<language>.lproj and reach the
/// app through scripts/build-agent.sh, outside this package; these tests read
/// them from the repository so drift between the two files, and between the
/// files and the code, fails here rather than in someone's menu bar.
@Suite struct UITextTests {
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")
    static let languages = ["en", "zh-Hans"]

    static func strings(_ language: String, table: String = "Localizable") throws
        -> [String: String]
    {
        let url = resources.appendingPathComponent("\(language).lproj/\(table).strings")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: String], "\(url.path) is not a strings table")
    }

    /// `%ld`, `%@`, `%.0f` and so on, in order of appearance.
    static func specifiers(_ text: String) -> [String] {
        // Width and precision, an optional length modifier, one conversion.
        let pattern = try! NSRegularExpression(pattern: #"%[0-9.]*l?[@dfsu]"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]) }
    }

    @Test func bothTablesParseAndCarryTheSameKeys() throws {
        let en = try Self.strings("en")
        let zh = try Self.strings("zh-Hans")
        #expect(!en.isEmpty)
        #expect(Set(en.keys) == Set(zh.keys))
    }

    @Test func englishValuesAreTheirKeysExceptTheOneLongText() throws {
        for (key, value) in try Self.strings("en") where key != "style-hint.body" {
            #expect(value == key, "en.lproj: \(key)")
        }
    }

    @Test func translationsKeepTheFormatSpecifiers() throws {
        let en = try Self.strings("en")
        for (key, value) in try Self.strings("zh-Hans") {
            #expect(
                Self.specifiers(value) == Self.specifiers(en[key] ?? key),
                "zh-Hans: \(key) → \(value)")
        }
    }

    @Test func everyKeyTheCodeUsesHasATranslation() throws {
        let sources = Self.resources.deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        let pattern = try NSRegularExpression(
            pattern: #"UIText\.(?:text|format)\(\s*"((?:[^"\\]|\\.)*)""#)
        var used: Set<String> = []
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        #expect(used.count >= 30, "the scan found \(used.count) keys; the regex may have broken")
        // The two notification titles share one call site; the scan sees neither.
        used.formUnion(["Task Complete", "Input Required"])
        for language in Self.languages {
            let keys = Set(try Self.strings(language).keys)
            #expect(used.subtracting(keys).isEmpty, "\(language) lacks \(used.subtracting(keys))")
        }
    }

    @Test func infoPlistStringsCoverTheAutomationPrompt() throws {
        for language in Self.languages {
            let table = try Self.strings(language, table: "InfoPlist")
            let description = table["NSAppleEventsUsageDescription"]
            #expect(description?.isEmpty == false, Comment(rawValue: language))
        }
    }

    /// A bundle whose only localization is Chinese answers in Chinese whatever
    /// the machine's language: the lookup itself, end to end through a real
    /// Bundle, with the repository's file.
    @Test func lookupThroughABundleReturnsTheTranslation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitext-\(UUID().uuidString).bundle")
        let lproj = root.appendingPathComponent("zh-Hans.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(
            at: Self.resources.appendingPathComponent("zh-Hans.lproj/Localizable.strings"),
            to: lproj.appendingPathComponent("Localizable.strings"))
        let bundle = try #require(Bundle(url: root))
        #expect(UIText.text("Task Complete", in: bundle) == "任务完成")
        #expect(
            UIText.format("Finished after %.0fm %.0fs", in: bundle, 5.0, 3.0) == "耗时 5 分 3 秒")
        #expect(UIText.format("Waiting · %ld", in: bundle, 3) == "等待中 · 3")
        #expect(UIText.text("not a key", in: bundle) == "not a key")
        #expect(UIText.text("k", default: "the English", in: bundle) == "the English")
    }

    /// The choice macOS makes for a Chinese user, given what the bundle ships.
    @Test func macOSPicksSimplifiedChineseForAChineseUser() {
        let shipped = Self.languages
        #expect(
            Bundle.preferredLocalizations(from: shipped, forPreferences: ["zh-CN"]) == ["zh-Hans"])
        #expect(Bundle.preferredLocalizations(from: shipped, forPreferences: ["en-GB"]) == ["en"])
        #expect(Bundle.preferredLocalizations(from: shipped, forPreferences: ["fr-FR"]) == ["en"])
    }

    /// No strings at all, as in this test process: the English comes back.
    @Test func withoutStringsTheEnglishIsTheAnswer() {
        #expect(UIText.text("Task Complete") == "Task Complete")
        #expect(UIText.format("Waiting · %ld", 2) == "Waiting · 2")
        #expect(MenuText.waitingHeader(3) == "Waiting · 3")
        #expect(MenuText.sessionsSeen(1) == "1 session seen in the last 24h")
        #expect(MenuText.sessionsSeen(4) == "4 sessions seen in the last 24h")
    }
}
