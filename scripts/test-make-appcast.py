#!/usr/bin/env python3
"""Checks the appcast that make-appcast.py writes; no extra dependencies.

    python3 scripts/test-make-appcast.py
"""
import pathlib, subprocess, sys, tempfile, unittest
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ROOT = pathlib.Path(__file__).resolve().parent.parent


class AppcastTests(unittest.TestCase):
    def run_script(self, *args):
        return subprocess.run([sys.executable, 'scripts/make-appcast.py', *map(str, args)], cwd=ROOT, capture_output=True, text=True)

    def fixture(self, folder, payload=b'alcove archive'):
        archive = folder / 'Alcove-0.2.3-macos-arm64.zip'
        archive.write_bytes(payload)
        signature = folder / 'signature.txt'
        signature.write_text(f'sparkle:edSignature="QUJDsig==" length="{len(payload)}"\n')
        return archive, signature

    def test_the_item_carries_the_build_number_and_a_signed_enclosure(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = pathlib.Path(tmp)
            archive, signature = self.fixture(folder)
            result = self.run_script('0.2.3', '5', archive, signature)
            self.assertEqual(result.returncode, 0, result.stderr)
            item = ET.parse(folder / 'appcast.xml').getroot().find('channel/item')
            self.assertEqual(item.find(f'{{{SPARKLE}}}version').text, '5')
            self.assertEqual(item.find(f'{{{SPARKLE}}}shortVersionString').text, '0.2.3')
            self.assertEqual(item.find(f'{{{SPARKLE}}}minimumSystemVersion').text, '15.0')
            enclosure = item.find('enclosure')
            self.assertEqual(enclosure.get('length'), str(len(b'alcove archive')))
            self.assertEqual(enclosure.get(f'{{{SPARKLE}}}edSignature'), 'QUJDsig==')
            self.assertEqual(enclosure.get('url'),
                             'https://github.com/YangTaeyoung/alcove/releases/download/v0.2.3/Alcove-0.2.3-macos-arm64.zip')

    def test_a_length_mismatch_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = pathlib.Path(tmp)
            archive, signature = self.fixture(folder)
            archive.write_bytes(b'changed after signing')
            result = self.run_script('0.2.3', '5', archive, signature)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((folder / 'appcast.xml').exists())

    def test_a_non_numeric_build_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = pathlib.Path(tmp)
            archive, signature = self.fixture(folder)
            result = self.run_script('0.2.3', '0.2.3', archive, signature)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((folder / 'appcast.xml').exists())


if __name__ == '__main__':
    unittest.main()
