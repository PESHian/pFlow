"""Use environment secrets in a disposable CI keychain, then remove it."""
import base64
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
from mac_release import run


def main():
    names = ['PFLOW_CERTIFICATE_P12', 'PFLOW_CERTIFICATE_PASSWORD', 'PFLOW_NOTARY_APPLE_ID', 'PFLOW_NOTARY_PASSWORD']
    values = {name: os.environ.pop(name, '') for name in names}
    if not all(values.values()):
        raise SystemExit('Configure the protected Mac release environment secrets')
    with tempfile.TemporaryDirectory(prefix='pflow-signing-', dir=os.environ['RUNNER_TEMP']) as directory:
        root = Path(directory); root.chmod(0o700)
        certificate = root / 'identity.p12'
        certificate.write_bytes(base64.b64decode(values['PFLOW_CERTIFICATE_P12'], validate=True)); certificate.chmod(0o600)
        keychain = root / 'release.keychain-db'
        password = secrets.token_hex(32)
        try:
            run('security', 'create-keychain', '-p', password, keychain)
            run('security', 'set-keychain-settings', '-lut', '21600', keychain)
            run('security', 'unlock-keychain', '-p', password, keychain)
            run('security', 'import', certificate, '-k', keychain, '-P', values['PFLOW_CERTIFICATE_PASSWORD'], '-T', '/usr/bin/codesign')
            run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain)
            run('xcrun', 'notarytool', 'store-credentials', 'pflow-release', '--keychain', keychain,
                '--apple-id', values['PFLOW_NOTARY_APPLE_ID'], '--password', values['PFLOW_NOTARY_PASSWORD'],
                '--team-id', os.environ['PFLOW_DEVELOPER_TEAM'])
            certificate.unlink()
            env = dict(os.environ, PFLOW_SIGNING_KEYCHAIN=str(keychain), YAP_NOTARY_PROFILE='pflow-release')
            subprocess.run([sys.executable, 'scripts/mac_release.py', '--app', 'build/Build/Products/Release/pFlow.app'], env=env, check=True)
        finally:
            if keychain.exists():
                run('security', 'delete-keychain', keychain)


if __name__ == '__main__':
    main()
