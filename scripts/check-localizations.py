#!/usr/bin/env python3
"""Validate localization source tables, or a built macOS app (--app PATH).

No third-party modules. This is a resource/packaging check, not a Swift build or UI test.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Sources/DigUpLocalization/Resources'
LANGUAGES = ('en', 'zh-Hans', 'zh-Hant')
ENTRY = re.compile(r'\s*("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;')
FORMAT = re.compile(r'%(?:(\d+)\$)?([-+ #0]*\d*(?:\.\d+)?)(@|[diuoxXfFeEgGcCsSp])|%%')


def table(path):
    data = path.read_bytes()
    if data.startswith((b'bplist', b'<?xml')):
        result = plistlib.loads(data)
        assert isinstance(result, dict) and all(isinstance(k, str) and isinstance(v, str) and v
                                              for k, v in result.items()), f'{path}: invalid string table'
        return result
    encoding = 'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
    text = re.sub(r'/\*.*?\*/', '', data.decode(encoding), flags=re.S)
    result, position = {}, 0
    while text[position:].strip():
        match = ENTRY.match(text, position)
        assert match, f'{path}: invalid .strings syntax near {text[position:position+60]!r}'
        key, value = map(json.loads, match.groups())
        assert key not in result, f'{path}: duplicate {key!r}'
        assert value, f'{path}: empty {key!r}'
        result[key] = value
        position = match.end()
    return result


def formats(value):
    tokens, end, implicit = [], 0, 0
    for match in FORMAT.finditer(value):
        assert '%' not in value[end:match.start()], f'Invalid format: {value!r}'
        end = match.end()
        if match[0] == '%%':
            tokens.append(('literal', '%'))
        else:
            implicit += 1
            tokens.append((int(match[1]) if match[1] else implicit, match[2] + match[3]))
    assert '%' not in value[end:], f'Invalid format: {value!r}'
    return Counter(tokens)


def validate_sources():
    english = table(RESOURCES / 'en.lproj/Localizable.strings')
    assert all(k == v for k, v in english.items()), 'English keys must be their fallback text'
    for language in LANGUAGES:
        translated = table(RESOURCES / f'{language}.lproj/Localizable.strings')
        assert translated.keys() == english.keys(), f'{language}: interface key mismatch'
        for key, value in translated.items():
            original, localized = formats(key), formats(value)
            assert not localized - original, f'{language}: invalid/repeated format arguments: {key}'
            # Only English noun arguments may be omitted in Chinese: count, progress,
            # date, path and all other dynamic values must survive.
            if language != 'en':
                omitted = original - localized
                noun_keys = {
                    ' · %1$@ long %2$@ to finish', '%1$@ %2$@ indexed',
                    '%1$@ %2$@ indexed yet', '%1$@ %2$@ waiting',
                    '%1$@ code %2$@ indexed', '%1$@ long %2$@',
                    '%1$@ long %2$@ to finish', '%1$@ weaker %2$@',
                    'Show all %1$@ %2$@…', '%1$@ %2$@ indexed · %3$@',
                    '%1$@ code %2$@ waiting · read after your other files',
                }
                allowed = Counter({(2, '@'): 1}) if key in noun_keys else Counter()
                assert not omitted - allowed, f'{language}: lost display values: {key}'
        print(f'{language}: {len(translated)} interface keys; format arguments valid')
    english_permissions = table(RESOURCES / 'en.lproj/InfoPlist.strings')
    plist = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    for language in LANGUAGES:
        permissions = table(RESOURCES / f'{language}.lproj/InfoPlist.strings')
        assert permissions.keys() == english_permissions.keys()
        assert all(k in plist and 'DigUp' in v for k, v in permissions.items())
        if language == 'en':
            assert all(plist[k] == v for k, v in permissions.items())
    # Check literal lookups too; dynamic keys are covered by Swift tests/manual review.
    for path in (ROOT / 'Sources/DigUpApp').glob('*.swift'):
        for key in re.findall(r'L10n\.(?:text|format)\(("(?:\\.|[^"\\])*")', path.read_text()):
            assert json.loads(key) in english, f'{path}: missing lookup {key}'
    assert plist['CFBundleIdentifier'] == 'com.abdurrahim.DigUp'
    assert 'defaultLocalization: "en"' in (ROOT / 'Package.swift').read_text()
    print('Permission keys, English fallback resources, literal UI lookups and production identity valid')


def validate_app(app):
    resources = app / 'Contents/Resources'
    bundle = resources / 'DigUp_DigUpLocalization.bundle'
    assert bundle.is_dir(), f'Missing SwiftPM resource bundle: {bundle}'
    for language in LANGUAGES:
        # SwiftPM can lowercase locale directory names; shipped main-bundle
        # permission directories retain the source spelling.
        localized = [p for p in bundle.iterdir() if p.name.casefold() == f'{language}.lproj'.casefold()]
        assert len(localized) == 1, f'Missing or ambiguous packaged locale: {language}'
        for filename in ('Localizable.strings', 'InfoPlist.strings'):
            source = table(RESOURCES / f'{language}.lproj' / filename)
            assert table(localized[0] / filename) == source
        assert table(resources / f'{language}.lproj/InfoPlist.strings') == table(
            RESOURCES / f'{language}.lproj/InfoPlist.strings')
    plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert plist['CFBundleIdentifier'] == 'com.abdurrahim.DigUp'
    assert plist['CFBundleDevelopmentRegion'] == 'en'
    print('Packaged localization tables, permission descriptions and production identity valid')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='also check a built macOS .app')
    args = parser.parse_args()
    validate_sources()
    if args.app:
        validate_app(args.app)
