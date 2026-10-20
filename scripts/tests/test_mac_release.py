import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mac_release', SCRIPTS / 'mac_release.py')
release = importlib.util.module_from_spec(spec); spec.loader.exec_module(release)
TEAM = 'PFLOWTEST1'
IDENTITY = 'A' * 40
ENV = dict(PFLOW_DEVELOPER_TEAM=TEAM, PFLOW_SIGNING_IDENTITY=IDENTITY, PFLOW_APPROVED_PUBLISHER='Fictional Publisher')


class MacReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'built.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Helpers').mkdir()
        for name in ['MacOS/pFlow', 'Helpers/whisper-cli']:
            (self.app / 'Contents' / name).write_bytes(bytes.fromhex('cffaedfe') + b'fictional')
        info = dict(CFBundleIdentifier='com.pesh.Yap', CFBundleExecutable='pFlow', CFBundleShortVersionString='0.3.6', PFLOWUpdateTeamID=TEAM)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        self.dist = self.root / 'dist'
        self.calls = []
        self.status = 'Accepted'
        self.fail = lambda args: False
        self.details = b'flags=0x10000(runtime)\nTimestamp=Oct 19, 2026\n'
        self.entitlements = {}
        self.gatekeeper = b'assessments enabled\n'
        self.stage = None
        self.addCleanup(patch.stopall)
        patch.object(release, 'run', side_effect=self.command).start()
        patch.object(release.subprocess, 'run', side_effect=lambda *a, **kw: SimpleNamespace(returncode=0, stderr=self.details)).start()

    def command(self, *values):
        args = tuple(map(str, values)); self.calls.append(args)
        if self.fail(args):
            raise RuntimeError('Controlled tool failure')
        if args[:2] == ('security', 'find-identity'):
            return (f'1) {"B"*40} "Developer ID Application: Another Publisher (OTHERTEAM1)"\n'
                    f'2) {IDENTITY} "Developer ID Application: Fictional Publisher ({TEAM})"\n').encode()
        if args[:3] == ('git', 'rev-parse', 'HEAD'):
            return b'c' * 40
        if args == ('spctl', '--status'):
            return self.gatekeeper
        if args[:3] == ('codesign', '--display', '--entitlements'):
            self.assertIn('--xml', args)
            return plistlib.dumps(self.entitlements)
        if args[0] == 'ditto' and '-c' not in args:
            shutil.copytree(args[1], args[2]); self.stage = Path(args[2]).parent
        if args[:3] == ('xcrun', 'notarytool', 'submit'):
            return json.dumps(dict(status=self.status, id='12345678-1234-1234-1234-123456789012')).encode()
        if args[:3] == ('xcrun', 'stapler', 'staple'):
            path = Path(args[3])
            if path.suffix == '.dmg': path.write_bytes(path.read_bytes() + b'-ticket')
            else: (path / 'ticket').write_bytes(b'fictional ticket')
        if args[:2] == ('hdiutil', 'create'):
            if any(a[:3] == ('xcrun', 'notarytool', 'submit') for a in self.calls):
                self.assertTrue((self.stage / 'pFlow by Pesh.app/ticket').exists())
            Path(args[-1]).write_bytes(b'fictional-dmg')
        if args[0] == 'codesign' and '--force' in args and args[-1].endswith('.dmg'):
            path = Path(args[-1]); path.write_bytes(path.read_bytes() + b'-signature')
        if args[:2] == ('hdiutil', 'attach'):
            mount = Path(args[args.index('-mountpoint')+1])
            shutil.copytree(self.stage / 'pFlow by Pesh.app', mount / 'pFlow by Pesh.app')
        return b''

    def package(self, **kwargs):
        return release.package(self.app, self.dist, env=ENV, **kwargs)

    def test_release_rejects_the_debug_self_test_entry(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'pFlow.app'
            macos = app / 'Contents/MacOS'; macos.mkdir(parents=True)
            (macos / 'pFlow').write_bytes(b'\x00code\x00--apply-update\x00')
            release.require_no_debug_entry(app)
            (macos / 'pFlow.debug.dylib').write_bytes(b'\x00code\x00--pflow-inline-selftest\x00')
            with self.assertRaises(ValueError):
                release.require_no_debug_entry(app)

    def test_release_rejects_a_home_folder_path_in_any_bundle_file(self):
        release.require_no_owner_paths(self.app)
        nested = self.app / 'Contents/Resources/en.lproj'; nested.mkdir(parents=True)
        (nested / 'notes.strings').write_bytes(b'built at /Users/ but no account, /home/runner/work')
        release.require_no_owner_paths(self.app)
        (self.app / 'Contents/Helpers/whisper-cli').write_bytes(bytes.fromhex('cffaedfe') + b'\x00/Users/fictional-builder/src/whisper.cpp\x00')
        with self.assertRaisesRegex(ValueError, 'Contents/Helpers/whisper-cli'):
            self.package(testing=True)
        self.assertFalse((self.dist / 'pFlow-Mac-0.3.6-testing.dmg').exists())
        self.assertFalse(any(a[:2] == ('hdiutil', 'create') for a in self.calls))

    def test_signs_inside_out_and_hashes_only_final_bytes(self):
        dmg = self.package()
        self.assertEqual(dmg.read_bytes(), b'fictional-dmg-signature-ticket')
        receipt = json.loads(dmg.with_name(dmg.name + '.trusted.json').read_text())
        self.assertEqual(receipt['sha256'], hashlib.sha256(dmg.read_bytes()).hexdigest())
        self.assertEqual(receipt['bytes'], dmg.stat().st_size)
        self.assertEqual(receipt['teamID'], TEAM)
        signed = [a for a in self.calls if a[0] == 'codesign' and '--force' in a]
        self.assertTrue(signed[0][-1].endswith('whisper-cli'))
        self.assertTrue(signed[-2][-1].endswith('.app'))
        self.assertTrue(all(IDENTITY in a for a in signed))
        self.assertEqual(sum(a[:3] == ('xcrun', 'notarytool', 'submit') for a in self.calls), 2)

    def test_notary_exit_zero_without_accepted_is_rejected(self):
        for status in ['Invalid', 'In Progress', 'Rejected', '']:
            with self.subTest(status=status):
                self.status = status
                with self.assertRaises(ValueError): self.package()
                self.assertFalse(list(self.dist.glob('*.trusted.json')))

    def test_failed_trust_step_never_creates_receipt(self):
        for step in [('codesign', '--verify'), ('spctl', '--assess'), ('xcrun', 'stapler', 'validate')]:
            with self.subTest(step=step):
                self.fail = lambda args: args[:len(step)] == step
                with self.assertRaises(RuntimeError): self.package()
                self.assertFalse(list(self.dist.glob('*.trusted.json')))

    def test_dmg_assessment_failure_blocks_distribution(self):
        self.fail = lambda args: args[0] == 'spctl' and args[-1].endswith('.dmg')
        with self.assertRaises(RuntimeError): self.package()
        self.assertFalse(list(self.dist.glob('*.dmg')))

    def test_timestamp_and_runtime_are_required(self):
        for details in [b'flags=0x10000(runtime)\n', b'Timestamp=Oct 19, 2026\n']:
            self.details = details
            with self.assertRaises(ValueError): self.package()

    def test_debug_entitlement_is_rejected(self):
        self.entitlements = {'com.apple.security.get-task-allow': True}
        with self.assertRaises(ValueError): self.package()
        self.assertFalse(list(self.dist.glob('*.trusted.json')))

    def test_disabled_gatekeeper_cannot_authorize_receipt(self):
        self.gatekeeper = b'assessments disabled\n'
        with self.assertRaises(ValueError): self.package()
        self.assertFalse(any(a[:2] == ('xcrun', 'notarytool') for a in self.calls))

    def test_wrong_team_identity_or_unapproved_publisher_fails(self):
        for field, value in [('PFLOW_DEVELOPER_TEAM', 'OTHERTEAM1'), ('PFLOW_SIGNING_IDENTITY', 'B'*40), ('PFLOW_APPROVED_PUBLISHER', 'Someone Else')]:
            with self.subTest(field=field):
                with self.assertRaises(ValueError): release.package(self.app, self.dist, env=dict(ENV, **{field:value}))
        self.assertFalse(any(a[:2] == ('xcrun', 'notarytool') for a in self.calls))

    def test_only_the_pflow_executable_is_packaged(self):
        info = plistlib.loads((self.app / 'Contents/Info.plist').read_bytes())
        for name in ['Yap', '../pFlow', 'Other']:
            with self.subTest(name=name):
                (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(info, CFBundleExecutable=name)))
                with self.assertRaises(ValueError): self.package(testing=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        executable = self.app / 'Contents/MacOS/pFlow'
        executable.unlink(); executable.symlink_to(self.app / 'Contents/Helpers/whisper-cli')
        with self.assertRaises(ValueError): self.package(testing=True)
        self.assertFalse(any(a[0] == 'lipo' for a in self.calls))
        self.assertFalse(list(self.dist.glob('*.dmg')))

    def test_testing_removes_stale_receipt_and_never_notarizes(self):
        self.dist.mkdir()
        (self.dist / 'pFlow-Mac-0.3.6-testing.dmg.trusted.json').write_text('stale')
        self.package(testing=True)
        self.assertFalse(list(self.dist.glob('*.trusted.json')))
        self.assertFalse(any(a[0] == 'security' or a[:2] == ('xcrun', 'notarytool') for a in self.calls))


if __name__ == '__main__': unittest.main()
