import Foundation
import Testing
@testable import DigUpLocalization

struct SimplifiedChineseTests {
    private func bundle(_ language: String) throws -> Bundle {
        // SwiftPM normalizes locale directories to lowercase on case-sensitive platforms.
        let path = try #require(L10n.bundle.path(forResource: language, ofType: "lproj")
                                ?? L10n.bundle.path(forResource: language.lowercased(), ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private func strings(_ language: String, table: String = "Localizable") throws -> [String: String] {
        let url = try #require(try bundle(language).url(forResource: table, withExtension: "strings"))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                           as? [String: String])
    }

    @Test func simplifiedChineseHasEveryInterfaceAndPermissionKey() throws {
        for table in ["Localizable", "InfoPlist"] {
            let english = try strings("en", table: table)
            let simplified = try strings("zh-Hans", table: table)
            #expect(Set(english.keys) == Set(simplified.keys))
            #expect(simplified.values.allSatisfy { !$0.isEmpty })
        }
        let permissions = try strings("zh-Hans", table: "InfoPlist")
        #expect(permissions.count == 5)
        #expect(permissions.values.allSatisfy { $0.contains("DigUp") })
    }

    // This is a macOS UI contract. swift-corelibs-foundation does not implement
    // Darwin’s locale negotiation, so a Linux pass must not claim to validate it.
    #if os(macOS)
    @Test func chineseRegionsSelectTheCorrectScriptAndUnsupportedLanguagesUseEnglish() {
        let available = ["en", "zh-Hans", "zh-Hant"]
        for preference in ["zh-Hans", "zh-CN", "zh-SG"] {
            #expect(Bundle.preferredLocalizations(from: available, forPreferences: [preference]).first == "zh-Hans")
        }
        for preference in ["zh-Hant", "zh-TW", "zh-HK"] {
            #expect(Bundle.preferredLocalizations(from: available, forPreferences: [preference]).first == "zh-Hant")
        }
        #expect(Bundle.preferredLocalizations(from: available, forPreferences: ["fr-FR"]).first == "en")
    }

    #endif

    @Test func fallbackAndDynamicDisplayValuesArePreserved() throws {
        let simplified = try bundle("zh-Hans")
        func format(_ key: String, _ args: CVarArg...) -> String {
            String(format: simplified.localizedString(forKey: key, value: nil, table: "Localizable"), arguments: args)
        }
        #expect(simplified.localizedString(forKey: "Settings…", value: nil, table: nil) == "设置…")
        #expect(simplified.localizedString(forKey: "missing.translation.key", value: nil, table: nil)
                == "missing.translation.key")
        #expect(format("Indexing %1$@%% · %2$@ of %3$@", "42", "21", "50")
                == "创建索引中 42% · 21／50")
        #expect(format("Show all %1$@ %2$@…", "42", "results") == "显示全部 42 条结果…")
        #expect(format("The chosen %1$@ is %2$@, not %3$@", "模型 % 文件.gguf", "10 MB", "865 MB")
                == "选择的 模型 % 文件.gguf 大小为 10 MB，应为 865 MB")
        #expect(format("%1$@ code files waiting · indexing from %2$@", "12", "01:00")
                == "12 个代码文件等待中 · 将于 01:00 开始创建索引")
        #if os(macOS)
        #expect(format("%1$@ %2$@ indexed · %3$@", "42", "files", "将于 01:00 开始创建索引")
                == "已为 42 个文件创建索引 · 将于 01:00 开始创建索引")
        #endif
        #expect(format("%.1f h", 1.5) == "1.5 小时")
        let traditional = try bundle("zh-Hant")
        #expect(String(format: traditional.localizedString(forKey: "Show all %1$@ %2$@…", value: nil, table: nil),
                       arguments: ["42", "results"]) == "顯示全部 42 筆結果…")
        let english = try bundle("en")
        #expect(english.localizedString(forKey: "Settings…", value: nil, table: nil) == "Settings…")
    }
}
