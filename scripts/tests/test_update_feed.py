import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('publisher', Path(__file__).resolve().parents[1] / 'publish-update-feed.py')
publisher = importlib.util.module_from_spec(spec); spec.loader.exec_module(publisher)
TEAM = 'PFLOWTEST1'


def asset(name):
    return dict(name=name, size=123, digest='sha256:'+'a'*64,
                browser_download_url='https://github.com/PESHian/pFlow/releases/download/fixture/'+name)


class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        self.mac = asset('pFlow-Mac-0.3.6-testing.dmg')
        self.release = dict(draft=False, tag_name='fixture', assets=[self.mac])
        self.previous = dict(schema=1, targets={
            'mac-arm64':dict(version='0.3.5',url='https://example.invalid/legacy',bytes=42,sha256='b'*64),
            **{'windows-'+a:dict(version='0.1.13',url='https://example.invalid/'+a,bytes=42,sha256='b'*64) for a in ['x64','x86','arm64']}})
        self.receipt = dict(schema=1,platform='mac-arm64',version='0.3.6',file=self.mac['name'],bytes=123,sha256='a'*64,teamID=TEAM,
                            sourceCommit='c'*40,appStapled=True,dmgStapled=True,gatekeeper=True,
                            appNotarization=dict(id='12345678-1234-1234-1234-123456789012',status='Accepted'),
                            dmgNotarization=dict(id='23456789-1234-1234-1234-123456789012',status='Accepted'))

    def merge(self, receipt=None):
        return publisher.merge(self.release,self.previous,{self.mac['name']:receipt or self.receipt},TEAM)

    def test_mac_update_preserves_every_windows_entry(self):
        original=copy.deepcopy(self.previous)
        feed,found=self.merge()
        self.assertEqual(found,1)
        for arch in ['x64','x86','arm64']:
            self.assertEqual(feed['targets']['windows-'+arch],original['targets']['windows-'+arch])
        self.assertEqual(self.previous,original)
        self.assertTrue(feed['targets']['mac-arm64']['url'].endswith('-testing.dmg'))

    def test_no_receipt_or_changed_receipt_blocks_mac(self):
        with self.assertRaises(ValueError): publisher.merge(self.release,self.previous)
        for key,value in [('sha256','b'*64),('bytes',124),('teamID','OTHERTEAM1'),('gatekeeper',False),('appStapled',False),('dmgStapled',False),('version','0.3.7'),('sourceCommit','')]:
            with self.subTest(key=key):
                with self.assertRaises(ValueError): self.merge(dict(self.receipt,**{key:value}))
        changed=copy.deepcopy(self.receipt);changed['appNotarization']['status']='Invalid'
        with self.assertRaises(ValueError):self.merge(changed)

    def test_legacy_mac_does_not_block_windows_release(self):
        self.release['assets']=[asset('pFlow-Windows-x64-0.1.14-update.zip'),asset('pFlow-Mac-0.3.5-testing.dmg')]
        self.release['assets'][1]['digest']='sha256:'+'b'*64
        feed,found=publisher.merge(self.release,self.previous)
        self.assertEqual(found,1)
        self.assertEqual(feed['targets']['mac-arm64'],self.previous['targets']['mac-arm64'])
        self.assertEqual(feed['targets']['windows-arm64'],self.previous['targets']['windows-arm64'])
        with patch.object(publisher,'urlopen',side_effect=AssertionError('No legacy receipt download')):
            self.assertEqual(publisher.mac_receipts(self.release,self.previous,''),{})

    def test_downgrade_and_same_version_binary_change_rules_remain(self):
        self.release['assets']=[asset('pFlow-Mac-0.3.4-testing.dmg')]
        self.assertEqual(publisher.merge(self.release,self.previous),(self.previous,0))
        self.release['assets']=[asset('pFlow-Mac-0.3.5-testing.dmg')]
        with self.assertRaises(ValueError): publisher.merge(self.release,self.previous)

    def test_receipt_needs_attestation_from_protected_main_workflow(self):
        data=json.dumps(self.receipt).encode()
        proof=asset(self.mac['name']+'.trusted.json');proof.update(size=len(data),digest='sha256:'+hashlib.sha256(data).hexdigest())
        self.release['assets'].append(proof)
        with patch.object(publisher,'urlopen',side_effect=lambda *a,**kw:io.BytesIO(data)), patch.object(publisher,'command',return_value=b'') as command:
            receipts=publisher.mac_receipts(self.release,self.previous,TEAM)
            self.assertEqual(receipts[self.mac['name']],self.receipt)
            args=command.call_args.args[0]
            self.assertIn('PESHian/pFlow/.github/workflows/mac-trusted-release.yml',args)
            self.assertIn('refs/heads/main',args)
            self.assertIn('--deny-self-hosted-runners',args)
            self.assertIn('c'*40,args)
        with patch.object(publisher,'urlopen',side_effect=lambda *a,**kw:io.BytesIO(data)), patch.object(publisher,'command',side_effect=RuntimeError('Untrusted attestation')):
            with self.assertRaises(RuntimeError): publisher.mac_receipts(self.release,self.previous,TEAM)


if __name__ == '__main__': unittest.main()
