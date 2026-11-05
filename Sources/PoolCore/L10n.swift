import Foundation

public enum L10n {
    /// Catalog codes with their own name, shown in Settings in that language.
    public static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("ja", "日本語"), ("ko", "한국어"),
    ]

    private static let catalogs: [String: [String: String]] = {
        let installed = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("ClaudeDesktopPool_PoolCore.bundle"))
        }
        #if POOL_PACKAGED_BUILD
        guard let bundle = installed else { return [:] }
        #else
        let bundle = installed ?? Bundle.module
        #endif
        return Dictionary(uniqueKeysWithValues: languages.map(\.code).map { language in
            let url = bundle.url(forResource: language, withExtension: "json", subdirectory: "Localizations")
            let values = url.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            return (language, values)
        })
    }()

    public static func resolvedLanguage(_ language: String) -> String {
        let candidates = language == "system" ? Locale.preferredLanguages : [language]
        for candidate in candidates {
            if let match = catalogLanguage(candidate) { return match }
        }
        return "en"
    }

    private static func catalogLanguage(_ identifier: String) -> String? {
        let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
        guard let base = parts.first else { return nil }
        if base == "zh" {
            let traditional = parts.contains("hant") || parts.contains { ["tw", "hk", "mo"].contains($0) }
            return traditional && !parts.contains("hans") ? "zh-Hant" : "zh-Hans"
        }
        if base == "pt" { return "pt-BR" }
        return languages.first { $0.code == base }?.code
    }

    public static func tr(_ source: String, language: String = "system", arguments: [String] = []) -> String {
        var value = catalogs[resolvedLanguage(language)]?[source] ?? source
        for (index, argument) in arguments.enumerated() {
            value = value.replacingOccurrences(of: "{\(index)}", with: argument)
        }
        return value
    }
}
