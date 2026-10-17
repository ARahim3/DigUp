# macOS interface localization

DigUp follows the language selected for the app in macOS. English is its development
language and fallback. Simplified Chinese uses `zh-Hans` (including `zh-CN` and
`zh-SG`); Traditional Chinese uses `zh-Hant` (including `zh-TW` and `zh-HK`). This
change localizes the native macOS UI only, not the Windows/Linux Tauri shell or CLI.

## Framework origin and integration

The localization framework, English/Traditional Chinese tables and native UI
call-site changes are adapted from [PR #34 by max0071001](https://github.com/ARahim3/DigUp/pull/34),
through commit `ef69d2658fbdd5885626ddc68e5e7b12f7523fa7`. Credit for that work belongs
to its original author. The Simplified Chinese table follows those same keys and
adapts the Traditional Chinese translations with mainland Chinese UI terminology.
The `Show all` Traditional Chinese string also corrects a duplicated count. The
previously untranslated `receipt` example is localized in all three languages.

Main does not yet contain that framework. A main-based proposal includes its
localization-only delta, ported onto `ec28973`; it overlaps with and depends on
agreement about #34. If #34 merges first, only the language/test additions and the
small count correction should be retained and rebased. No separate runtime or
fork-specific app identity is introduced.

## Resources and formatting

`Sources/DigUpLocalization/Resources/{en,zh-Hans,zh-Hant}.lproj` each contain
`Localizable.strings` (425 keys) and `InfoPlist.strings` (five permission descriptions).

`L10n.text` looks up static interface text. `L10n.format` formats display values with
positional `%1$@`, `%2$@`, etc. The English format is also the lookup key. Pass
already formatted strings, for example a count's `.formatted()` value, and escape
literal percent signs as `%%`. Chinese may omit an English singular/plural noun
argument, but must preserve counts, paths, times and other display values. Numeric
duration formats such as `%.1f h` keep their original specifiers.

Search terms, tokenizer behavior, model prompts, file paths, stored settings keys,
helper commands and diagnostics are unchanged. Translated sample queries are UI
examples only. System errors and third-party UI retain their own localization.

`build.sh` embeds `DigUp_DigUpLocalization.bundle` in `Contents/Resources` and copies
each locale's `InfoPlist.strings` into the main app bundle for macOS permission
prompts. App name, bundle ID, index location and update feed stay production defaults.

## Checks

Run dependency-free source and packaging-command fixture checks:

```
python3 scripts/check-localizations.py
python3 scripts/test-localizations.py
```

The fixture uses a mock SwiftPM bundle and runs the actual resource-copy block from
`build.sh`; it is not a real macOS build. Source validation checks unique/nonempty
keys, exact language-key parity, positional argument types/multiplicity, literal
percent signs, permission parity and literal UI lookup coverage. Swift tests also
exercise key fallback and dynamic display values. Region negotiation and runtime
formatting with positional gaps (such as `%1$@` followed by `%3$@`) are asserted on
macOS only: Linux swift-corelibs-foundation does not implement Darwin’s language
negotiation and consumes the wrong argument for positional gaps. Static format
validation still covers every resource on Linux; this is not a claim of macOS UI
validation. Test resource lookup accepts SwiftPM’s lowercase locale directories on
case-sensitive filesystems.

Before publishing a release, on macOS with the documented build dependencies:

```
swift test
./build.sh
python3 scripts/check-localizations.py --app build.noindex/DigUp.app
codesign --verify --deep --strict build.noindex/DigUp.app
```

Inspect the packaged app in English, `zh-CN`, `zh-Hans`, `zh-TW` and an unsupported
language such as French. Cover onboarding; search and no results; menus; all
settings tabs; code search; scheduled indexing; paused/progress states; manual
model selection and download errors; and long names/counts/percent signs. Check
Close/Back/Cancel and reopening flows, truncation and accessibility labels. Verify
permission descriptions in packaged resources and, in an appropriate test account,
live macOS permission prompts. Do not reuse historical #34 screenshots or test
counts as evidence that this rebased Simplified Chinese build passed.
