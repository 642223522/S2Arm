// UI adapted from LumaDock (MIT); see ../../README.md.
import Foundation
import S2ArmAppleAdapter

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: return L("跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if self != .system { return rawValue }
        for language in preferredLanguages {
            let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if code == "zh" || code.hasPrefix("zh-") { return "zh-Hans" }
            if code == "en" || code.hasPrefix("en-") { return "en" }
        }
        return "en"
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }
}

/// Translate presentation only. Worker records retain their canonical messages so
/// old jobs can switch language without changing cache identities or player data.
/// 翻译引擎、对照表与共享体验文案的加载在适配层 BackendText（新旧前端共用一份）；这里只管旧启动器的语言选择。
enum Localization {
    static var preference = AppLanguage.system
    static var language: String { preference.resolved() }
    static var locale: Locale { Locale(identifier:language) }
    static func translate(_ text: String, language: String) -> String { BackendText.translate(text,language:language) }
}

// Keep canonical job messages and old journals unchanged; terminology belongs to presentation.
func L(_ text: String) -> String {
    let value = Localization.translate(text,language:Localization.language)
    if Localization.language == "en" {
        guard text.contains("打包") else {return value}
        return value.replacingOccurrences(of:#"\bPacking\b"#,with:"Compiling",options:.regularExpression)
            .replacingOccurrences(of:#"\bpacking\b"#,with:"compiling",options:.regularExpression)
            .replacingOccurrences(of:#"\bpacked\b"#,with:"compiled",options:.regularExpression)
    }
    return value.replacingOccurrences(of:"打包",with:"编译")
}
