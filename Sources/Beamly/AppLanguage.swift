import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case en, ru, de, fr, es

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        }
    }

    @discardableResult
    static func configureAtLaunch(defaults: UserDefaults = .standard) -> AppLanguage {
        let language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .en
        // Set before creating views or Sparkle so native dialogs use the same language.
        defaults.set([language.rawValue], forKey: "AppleLanguages")
        return language
    }
}
