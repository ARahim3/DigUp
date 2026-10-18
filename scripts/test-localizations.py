#!/usr/bin/env python3
"""Dependency-free regression checks for the localization resource validator."""
import importlib.util
from pathlib import Path
import shutil
import plistlib
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('localizations', Path(__file__).with_name('check-localizations.py'))
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class ResourceTests(unittest.TestCase):
    def test_valid_resources(self):
        checks.validate_sources()

    def test_packaged_binary_and_utf16_tables(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Localizable.strings'
            path.write_bytes(plistlib.dumps({'Settings…': '设置…'}, fmt=plistlib.FMT_BINARY))
            self.assertEqual(checks.table(path), {'Settings…': '设置…'})
            path.write_bytes('"Settings…" = "设置…";'.encode('utf-16'))
            self.assertEqual(checks.table(path), {'Settings…': '设置…'})

    def test_rejects_duplicate_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Localizable.strings'
            path.write_text('"key" = "one";\n"key" = "two";')
            with self.assertRaisesRegex(AssertionError, 'duplicate'):
                checks.table(path)

    def test_rejects_malformed_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Localizable.strings'
            path.write_text('"key" = "unterminated;')
            with self.assertRaisesRegex(AssertionError, 'syntax'):
                checks.table(path)

    def test_checks_argument_types_and_multiplicity(self):
        original = checks.formats('%1$@ %2$@')
        self.assertTrue(checks.formats('%1$@ %1$@') - original)
        self.assertTrue(checks.formats('%1$d %2$@') - original)
        self.assertFalse(checks.formats('%2$@ %1$@') - original)
        self.assertEqual(checks.formats('%.1f h'), checks.formats('%.1f 小时'))

    def test_rejects_unescaped_percent(self):
        with self.assertRaisesRegex(AssertionError, 'Invalid format'):
            checks.formats('%1$@% · 进度')
        self.assertEqual(checks.formats('%1$@%%'), checks.formats('%1$@%%'))

    def test_actual_packaging_commands_with_mock_swiftpm_bundle(self):
        # Execute the real resource-copy section, with a mock SwiftPM output and
        # portable ditto substitute. Does not prove SwiftPM emits the bundle.
        build = (checks.ROOT / 'build.sh').read_text()
        section = build.split('# SwiftPM\'s localization bundle')[1].split('# Sparkle')[0]
        section = section.split('\n', 1)[1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'DigUp.app'
            resources = app / 'Contents/Resources'
            resources.mkdir(parents=True)
            shutil.copy(checks.ROOT / 'Resources/Info.plist', app / 'Contents/Info.plist')
            bin_dir = root / 'bin'
            shutil.copytree(checks.RESOURCES, bin_dir / 'DigUp_DigUpLocalization.bundle')
            subprocess.run(['bash', '-euc', 'ditto() { cp -R "$1" "$2"; };\n' + section],
                           cwd=checks.ROOT, env={'APP': str(app), 'BIN_DIR': str(bin_dir), 'PATH': '/usr/bin:/bin'},
                           check=True)
            checks.validate_app(app)
            bundle = resources / 'DigUp_DigUpLocalization.bundle'
            for language in ('zh-Hans', 'zh-Hant'):
                (bundle / f'{language}.lproj').rename(bundle / f'{language.lower()}.lproj')
            checks.validate_app(app)
            (resources / 'zh-Hans.lproj/InfoPlist.strings').unlink()
            with self.assertRaises(FileNotFoundError):
                checks.validate_app(app)


if __name__ == '__main__':
    unittest.main()
