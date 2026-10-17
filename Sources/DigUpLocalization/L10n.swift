import Foundation

/// Interface localization only. Queries, file paths, persisted settings and helper protocols keep their original values.
public enum L10n {
    static let bundle = Bundle.module

    public static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    /// Positional arguments let a translation reorder display values without changing their formatting.
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
