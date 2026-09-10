import Foundation

enum L10n {
    static func language(for preferences: [String]) -> String {
        let primary = preferences.first?.split(separator: "-").first.map(String.init) ?? "en"
        switch primary {
        case "ko", "ja", "en": return primary
        case "zh": return "zh-Hans"
        default: return "en"
        }
    }

    static let language = language(for: Locale.preferredLanguages)
    static let locale = Locale(identifier: language)

    static func text(_ key: String, language: String = language) -> String {
        let path = Bundle.module.path(forResource: language, ofType: "lproj")
            ?? Bundle.module.path(forResource: "en", ofType: "lproj")!
        return Bundle(path: path)!.localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    static func date(_ date: Date, includeTime: Bool = true) -> String {
        let style = Date.FormatStyle.dateTime.year().month(.defaultDigits).day().locale(locale)
        return date.formatted(includeTime ? style.hour().minute() : style)
    }
}
