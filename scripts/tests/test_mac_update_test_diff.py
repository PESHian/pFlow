import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mac_update_test_diff', SCRIPTS / 'mac_update_test_diff.py')
diff = importlib.util.module_from_spec(spec); spec.loader.exec_module(diff)
MACHO = bytes.fromhex('cffaedfe')


def fake_strip(path, scratch):
    """Stands in for codesign --remove-signature: the fictional signature is everything after 'SIG'."""
    return Path(path).read_bytes().split(b'SIG')[0]


class UpdateTestDiffTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.release = self.volume('release', '0.3.18', b'SIG-release')
        self.test = self.volume('test', '0.3.16', b'SIG-test')

    def volume(self, name, version, signature):
        root = Path(self.temp.name) / name
        app = root / diff.APP / 'Contents'
        (app / 'MacOS').mkdir(parents=True)
        (app / '_CodeSignature').mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.pesh.Yap', CFBundleShortVersionString=version, CFBundleVersion='46')))
        (app / 'MacOS/pFlow').write_bytes(MACHO + b'fictional code' + signature)
        (app / '_CodeSignature/CodeResources').write_bytes(b'fictional hashes ' + signature)
        (app / 'Resources').mkdir()
        (app / 'Resources/words.txt').write_text('fictional resource')
        os.symlink('/Applications', root / 'Applications')
        return root

    def run_compare(self):
        return diff.compare(self.release, self.test, strip=fake_strip)

    def test_only_version_and_signatures_differ(self):
        compared, allowed, unexpected = self.run_compare()
        self.assertEqual(unexpected, [])
        self.assertEqual(compared, 4)
        self.assertEqual(len(allowed), 3)
        self.assertIn('CFBundleShortVersionString 0.3.18 -> 0.3.16', ' '.join(allowed))

    def test_a_code_change_is_caught(self):
        (self.test / diff.APP / 'Contents/MacOS/pFlow').write_bytes(MACHO + b'other code' + b'SIG-test')
        self.assertIn('code differs', ' '.join(self.run_compare()[2]))

    def test_another_plist_key_is_caught(self):
        info = self.test / diff.APP / 'Contents/Info.plist'
        values = plistlib.loads(info.read_bytes()); values['CFBundleIdentifier'] = 'com.pesh.Yap.debug'
        info.write_bytes(plistlib.dumps(values))
        self.assertIn('CFBundleIdentifier', ' '.join(self.run_compare()[2]))

    def test_a_changed_resource_is_caught(self):
        (self.test / diff.APP / 'Contents/Resources/words.txt').write_text('other fictional resource')
        self.assertIn('words.txt: bytes differ', ' '.join(self.run_compare()[2]))

    def test_an_extra_or_missing_file_is_caught(self):
        (self.test / diff.APP / 'Contents/Resources/extra.txt').write_text('fictional')
        (self.release / diff.APP / 'Contents/Resources/words.txt').unlink()
        problems = ' '.join(self.run_compare()[2])
        self.assertIn('extra.txt: only in the update-test DMG', problems)
        self.assertIn('words.txt: only in the update-test DMG', problems)

    def test_a_changed_link_or_mode_is_caught(self):
        (self.test / 'Applications').unlink(); os.symlink('/tmp', self.test / 'Applications')
        os.chmod(self.test / diff.APP / 'Contents/Resources/words.txt', 0o666)
        problems = self.run_compare()[2]
        self.assertTrue(any(p.startswith('Applications:') for p in problems))
        self.assertTrue(any(p.startswith(f'{diff.APP}/Contents/Resources/words.txt:') for p in problems))

    def test_a_resource_bundles_signature_files_may_differ(self):
        for root, signature in ((self.release, b'release'), (self.test, b'test')):
            folder = root / diff.APP / 'Contents/Resources/Shortcuts.bundle/Contents/_CodeSignature'
            folder.mkdir(parents=True)
            (folder / 'CodeDirectory').write_bytes(b'fictional directory ' + signature)
        compared, allowed, unexpected = self.run_compare()
        self.assertEqual(unexpected, [])
        self.assertIn('Shortcuts.bundle/Contents/_CodeSignature/CodeDirectory: signature', ' '.join(allowed))

    def test_a_file_outside_a_signature_folder_is_not_a_signature(self):
        for root, signature in ((self.release, b'release'), (self.test, b'test')):
            (root / diff.APP / 'Contents/Resources/_CodeSignature.txt').write_bytes(signature)
        self.assertIn('bytes differ', ' '.join(self.run_compare()[2]))

    def test_the_same_version_is_not_an_update_test(self):
        info = self.test / diff.APP / 'Contents/Info.plist'
        info.write_bytes((self.release / diff.APP / 'Contents/Info.plist').read_bytes())
        self.assertIn('must read an older version', ' '.join(self.run_compare()[2]))

    def test_a_newer_or_unreadable_version_is_not_an_update_test(self):
        info = self.test / diff.APP / 'Contents/Info.plist'
        for version in ('0.3.19', '0.4', 'fictional'):
            with self.subTest(version=version):
                info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.pesh.Yap', CFBundleShortVersionString=version, CFBundleVersion='46')))
                self.assertIn('must read an older version', ' '.join(self.run_compare()[2]))


if __name__ == '__main__':
    unittest.main()
