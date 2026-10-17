# Interface localization

DigUp follows the language selected for the app in macOS, with English as its development language and fallback.
Traditional Chinese uses `zh-Hant`, including the system's `zh-TW` preference.

The `DigUpLocalization` target contains `L10n` and these resources:

```
Sources/DigUpLocalization/Resources/
├── en.lproj/       Localizable.strings, InfoPlist.strings
└── zh-Hant.lproj/  Localizable.strings, InfoPlist.strings
```

`L10n.text` looks up static interface text. `L10n.format` formats display values with positional `%1$@`, `%2$@`, etc.
The English format is also the lookup key. Pass already formatted strings (for example a count's `.formatted()` value),
and escape a literal percent as `%%` in format strings. Translations may reorder or omit an argument; Chinese need not
include an English singular/plural noun supplied by the calling code. Keep both English noun forms for existing English
plural behavior. `String(format:)` duration formats such as `%.1f h` are translated before their existing formatting call.

To add a language, add its `.lproj` directory with both files and the same interface keys. Keep permission descriptions
consistent with the English Info.plist. Run `swift test`, build with `./build.sh`, and inspect the packaged app's UI in
both languages, including long explanatory text and strings with counts, percent signs, and file names.

`build.sh` embeds the SwiftPM resource bundle in `Contents/Resources`. It also copies each language's `InfoPlist.strings`
into the main app bundle so macOS can localize its permission prompts. This step matters: launching from the build
folder alone does not prove that the distributed `.app` includes its translations.

Search terms, tokenizer behavior, model prompts, file paths, stored settings keys, helper commands and diagnostics are
not localized. Sample queries shown in the UI may be translated; they are examples, not changes to search processing.
System error descriptions and third-party UI use the localization supplied by macOS or the dependency.


## Origin

Adapted from [PR #34 by max0071001](https://github.com/ARahim3/DigUp/pull/34), through commit `ef69d2658fbdd5885626ddc68e5e7b12f7523fa7`, onto current main `ec28973`. This is the original author’s localization framework and translations, not newly authored work. Historical screenshots and test counts are omitted because this rebased build has not been validated on macOS.
