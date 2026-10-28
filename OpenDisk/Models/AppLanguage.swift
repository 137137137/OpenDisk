import Foundation

enum AppLanguage {
    struct Option: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let automatic = ""

    static let supported = [
        "ar", "ca", "cs", "da", "de", "el", "en", "en-AU", "en-GB", "es", "es-419",
        "fi", "fr", "fr-CA", "he", "hi", "hr", "hu", "id", "it", "ja", "ko", "ms",
        "nb", "nl", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sv", "th", "tr",
        "uk", "vi", "zh-HK", "zh-Hans", "zh-Hant",
    ]

    private static let defaultsKey = "AppleLanguages"

    static let atLaunch = current

    static var current: String {
        guard let domain = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: domain)?[defaultsKey] as? [String],
              let first = languages.first else { return automatic }
        if supported.contains(first) { return first }
        return Bundle.preferredLocalizations(from: supported, forPreferences: [first]).first ?? automatic
    }

    static func select(_ code: String) {
        if code == automatic {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set([code], forKey: defaultsKey)
        }
    }

    static let options: [Option] = supported
        .map { Option(code: $0, name: displayName(for: $0)) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private static func displayName(for code: String) -> String {
        let locale = Locale(identifier: code)
        let native = locale.localizedString(forIdentifier: code) ?? code
        let endonym = native.prefix(1).uppercased(with: locale) + native.dropFirst()
        guard let translated = Locale.current.localizedString(forIdentifier: code),
              translated.localizedCaseInsensitiveCompare(native) != .orderedSame else { return endonym }
        return "\(endonym) — \(translated)"
    }
}
