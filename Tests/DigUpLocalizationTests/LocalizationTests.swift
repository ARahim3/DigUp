import Foundation
import Testing
@testable import DigUpLocalization

struct LocalizationTests {
    private func localizedBundle(_ language: String) throws -> Bundle {
        let path = try #require(L10n.bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private func strings(_ language: String) throws -> [String: String] {
        let bundle = try localizedBundle(language)
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    @Test func languagesHaveTheSameKeysAndEnglishFallsBackToItsKeys() throws {
        let english = try strings("en")
        let chinese = try strings("zh-Hant")
        #expect(english.count > 350)
        #expect(Set(english.keys) == Set(chinese.keys))
        for (key, value) in english { #expect(key == value) }
        #expect(chinese.values.allSatisfy { !$0.isEmpty })
        #expect(L10n.text("missing.translation.key") == "missing.translation.key")
    }

    @Test func translatedFormatsUseOnlyExistingArguments() throws {
        let english = try strings("en")
        let chinese = try strings("zh-Hant")
        let pattern = try NSRegularExpression(pattern: #"%(\d+)\$@"#)
        func arguments(_ value: String) -> Set<String> {
            Set(pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                (value as NSString).substring(with: $0.range(at: 1))
            })
        }
        for (key, value) in chinese {
            let translatedArguments = arguments(value)
            let originalArguments = arguments(english[key]!)
            #expect(translatedArguments.isSubset(of: originalArguments))
            if let count = originalArguments.compactMap(Int.init).max() {
                let values: [CVarArg] = (1...count).map { "⟦\($0)⟧" }
                let formatted = String(format: value, arguments: values)
                for argument in translatedArguments { #expect(formatted.contains("⟦\(argument)⟧")) }
            }
        }
    }

    @Test func dynamicValuesAndLiteralPercentSurviveTranslation() throws {
        let english = try localizedBundle("en")
        let chinese = try localizedBundle("zh-Hant")
        let key = "Indexing %1$@%% · %2$@ of %3$@"
        let args: [CVarArg] = ["42", "21", "50"]
        #expect(String(format: english.localizedString(forKey: key, value: nil, table: nil), arguments: args)
                == "Indexing 42% · 21 of 50")
        #expect(String(format: chinese.localizedString(forKey: key, value: nil, table: nil), arguments: args)
                == "建立索引中 42% · 21／50")
        #expect(chinese.localizedString(forKey: "Settings…", value: nil, table: nil) == "設定…")
    }

    @Test func scheduledIndexingAndManualModelFilesKeepDisplayValues() throws {
        let bundle = try localizedBundle("zh-Hant")
        func format(_ key: String, _ args: CVarArg...) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), arguments: args)
        }
        #expect(format("%1$@ code files waiting · indexing from %2$@", "12", "01:00")
                == "12 個程式碼檔案等待中 · 將於 01:00 開始建立索引")
        #expect(format("%1$@ %2$@ indexed · %3$@", "42", "files", "將於 01:00 開始建立索引")
                == "已為 42 個檔案建立索引 · 將於 01:00 開始建立索引")
        #expect(format("The chosen %1$@ is %2$@, not %3$@", "model.gguf", "10 MB", "865 MB")
                == "選取的 model.gguf 大小為 10 MB，應為 865 MB")
        #expect(bundle.localizedString(forKey: "Index only at set hours", value: nil, table: nil)
                == "只在指定時段建立索引")
        #expect(bundle.localizedString(forKey: "Use Files…", value: nil, table: nil) == "使用檔案…")
    }

    @Test func permissionDescriptionsAreLocalized() throws {
        for language in ["en", "zh-Hant"] {
            let bundle = try localizedBundle(language)
            let value = bundle.localizedString(forKey: "NSDocumentsFolderUsageDescription", value: nil, table: "InfoPlist")
            #expect(value.contains("DigUp"))
            #expect(value != "NSDocumentsFolderUsageDescription")
        }
    }
}
