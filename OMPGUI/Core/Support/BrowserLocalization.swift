import Foundation

enum BrowserInterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case app
    case english
    case simplifiedChinese

    static let preferenceKey = "browserInterfaceLanguage"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "Follow app language"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    func localizationIdentifier(appLocalization: String) -> String {
        switch self {
        case .app: appLocalization.lowercased().hasPrefix("zh-hans") ? "zh-Hans" : "en"
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }
}

/// One language snapshot for the native browser chrome and CEF's process-wide
/// locale. Changing the preference applies on the next application launch.
enum BrowserLocalization {
    private final class ResourceBundle: NSObject {}
    static let resources = Bundle(for: ResourceBundle.self)
    static let identifier: String = {
        let defaults = CaptureRun.defaults ?? .standard
        let language = BrowserInterfaceLanguage(rawValue: defaults.string(forKey: BrowserInterfaceLanguage.preferenceKey) ?? "") ?? .app
        return language.localizationIdentifier(appLocalization: resources.preferredLocalizations.first ?? "en")
    }()
    static let locale = Locale(identifier: identifier)
    static let chromiumLocale = identifier == "zh-Hans" ? "zh-CN" : "en-US"
    static let bundle = localizedBundle(for: identifier)

    static func localizedBundle(for identifier: String) -> Bundle {
        guard let path = resources.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resources }
        return bundle
    }

    static func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
