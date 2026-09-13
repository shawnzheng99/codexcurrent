import Foundation

enum AppLanguage: String, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var resourceName: String { rawValue.lowercased() }

    static var system: AppLanguage {
        if let override = ProcessInfo.processInfo.environment["CODEX_CURRENT_LANGUAGE"] {
            return override.lowercased().hasPrefix("zh") ? .simplifiedChinese : .english
        }
        guard let preferred = Locale.preferredLanguages.first else { return .english }
        let languageCode = Locale(identifier: preferred).language.languageCode?.identifier
        return languageCode == "zh" ? .simplifiedChinese : .english
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage = .system) -> String {
        localizedBundle(for: language).localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, language: AppLanguage = .system, _ arguments: CVarArg...) -> String {
        String(format: text(key, language: language), locale: Locale(identifier: language.rawValue), arguments: arguments)
    }

    private static func localizedBundle(for language: AppLanguage) -> Bundle {
        guard let path = Bundle.module.path(forResource: language.resourceName, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return Bundle.module }
        return bundle
    }
}
