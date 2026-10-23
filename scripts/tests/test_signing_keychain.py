import base64
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(SCRIPTS))
spec=importlib.util.spec_from_file_location('keychain',SCRIPTS/'mac_signing_keychain.py')
keychain=importlib.util.module_from_spec(spec);spec.loader.exec_module(keychain)
sys.path.pop(0)


class SigningKeychainTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.env=dict(RUNNER_TEMP=self.temp.name,PFLOW_DEVELOPER_TEAM='PFLOWTEST1',
                      PFLOW_CERTIFICATE_P12=base64.b64encode(b'fictional certificate').decode(),
                      PFLOW_CERTIFICATE_PASSWORD='fictional export password',
                      PFLOW_NOTARY_APPLE_ID='fictional@example.invalid',PFLOW_NOTARY_PASSWORD='fictional notary password')
        self.calls=[]
        self.fail_import=False
        self.addCleanup(patch.stopall)
        patch.dict(os.environ,self.env,clear=True).start()
        patch.object(keychain,'run',side_effect=self.command).start()

    def command(self,*args):
        self.calls.append(args)
        if args[:2]==('security','create-keychain'):Path(args[-1]).write_text('fictional keychain')
        if args[:2]==('security','import') and self.fail_import:raise RuntimeError('Controlled import failure')
        if args[:2]==('security','delete-keychain'):Path(args[-1]).unlink()
        return b''

    def test_secrets_not_inherited_and_keychain_removed(self):
        with patch.object(keychain.subprocess,'run') as child:
            keychain.main()
            env=child.call_args.kwargs['env']
            for name in ['PFLOW_CERTIFICATE_P12','PFLOW_CERTIFICATE_PASSWORD','PFLOW_NOTARY_APPLE_ID','PFLOW_NOTARY_PASSWORD']:
                self.assertNotIn(name,env)
            self.assertFalse(Path(env['PFLOW_SIGNING_KEYCHAIN']).exists())
        self.assertEqual(self.calls[-1][:2],('security','delete-keychain'))
        self.assertEqual(list(Path(self.temp.name).iterdir()),[])

    def test_failed_import_still_removes_keychain(self):
        self.fail_import=True
        with patch.object(keychain.subprocess,'run') as child:
            with self.assertRaises(RuntimeError):keychain.main()
            child.assert_not_called()
        self.assertEqual(self.calls[-1][:2],('security','delete-keychain'))
        self.assertEqual(list(Path(self.temp.name).iterdir()),[])


if __name__=='__main__':unittest.main()
