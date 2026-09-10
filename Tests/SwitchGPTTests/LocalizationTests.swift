import XCTest
@testable import SwitchGPT

final class LocalizationTests: XCTestCase {
    func testSystemLanguageAndEnglishFallback() {
        for (preference, expected) in [("ko-KR", "ko"), ("ja-JP", "ja"), ("zh-CN", "zh-Hans"), ("zh-Hant-TW", "zh-Hans"), ("en-GB", "en"), ("fr-FR", "en")] {
            XCTAssertEqual(L10n.language(for: [preference]), expected)
        }
        XCTAssertEqual(L10n.language(for: []), "en")
    }

    func testEveryTranslationAndFormatPlaceholderIsPresent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SwitchGPT/Resources")
        func strings(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: root.appendingPathComponent("\(language).lproj/Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try strings("en")
        let placeholders = try NSRegularExpression(pattern: "%[@d%]")
        func formats(_ text: String) -> [String] {
            placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        for language in ["ko", "zh-Hans", "ja", "en"] {
            let translated = try strings(language)
            XCTAssertEqual(Set(translated.keys), Set(english.keys))
            for (key, value) in english {
                let localized = L10n.text(key, language: language)
                XCTAssertEqual(localized, translated[key], "\(language): \(key)")
                XCTAssertFalse(localized.isEmpty)
                XCTAssertEqual(formats(localized), formats(value), "\(language): \(key)")
            }
        }
        XCTAssertEqual(L10n.text("accounts", language: "fr"), "ChatGPT Accounts")
    }
}
