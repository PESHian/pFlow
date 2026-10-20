"""Build a Developer ID release. Only verified final bytes get a trust receipt."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DEVELOPER_ID = ('anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
                'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
MACHO = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def run(*args):
    result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
    if result.returncode:
        # Tool output can contain certificate names or credential arguments.
        raise RuntimeError(f'{Path(args[0]).name} failed (exit {result.returncode}); no trusted release was produced')
    return result.stdout


def requirement(team):
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Set the approved PFLOW_DEVELOPER_TEAM')
    return DEVELOPER_ID + f' and certificate leaf[subject.OU] = "{team}"'


def preflight(env):
    team = env.get('PFLOW_DEVELOPER_TEAM', '')
    requirement(team)
    identity = env.get('PFLOW_SIGNING_IDENTITY', '')
    publisher = env.get('PFLOW_APPROVED_PUBLISHER', '')
    if not re.fullmatch(r'[A-Fa-f0-9]{40}', identity) or not publisher or any(c in publisher for c in '\r\n"'):
        raise ValueError('Set the exact signing identity SHA-1 and approved public publisher name')
    keychain = env.get('PFLOW_SIGNING_KEYCHAIN')
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning', *([keychain] if keychain else [])).decode()
    name = f'Developer ID Application: {publisher} ({team})'
    matches = re.findall(r'\b([A-Fa-f0-9]{40})\s+"([^"\n]+)"', identities)
    if (identity.upper(), name) not in [(fingerprint.upper(), label) for fingerprint, label in matches]:
        raise ValueError('The selected usable Developer ID identity does not match the approved publisher and team')
    if run('spctl', '--status').strip() != b'assessments enabled':
        raise ValueError('Enable Gatekeeper before preparing a trusted release')
    profile = env.get('YAP_NOTARY_PROFILE', 'yap-notary')
    notary = ['--keychain-profile', profile] + (['--keychain', keychain] if keychain else [])
    run('xcrun', 'notarytool', 'history', *notary, '--output-format', 'json')
    return team, identity, keychain, notary


def code_paths(app):
    paths = set()
    for path in app.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as file:
                if file.read(4) in MACHO:
                    paths.add(path)
    for path in app.rglob('*'):
        if path.is_dir() and not path.is_symlink() and path.suffix in {'.framework', '.app', '.xpc', '.appex', '.bundle'}:
            if any(path in code.parents for code in paths):
                paths.add(path)
    return sorted(paths, key=lambda path: (-len(path.parts), str(path))) + [app]


def verify_code(path, team):
    run('codesign', '--verify', '--deep', '--strict', '--all-architectures', '-R', '=' + requirement(team), path)
    result = subprocess.run(['codesign', '--display', '--verbose=4', str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    details = result.stderr.decode(errors='replace')
    if result.returncode or not re.search(r'flags=.*\bruntime\b', details) or not re.search(r'^Timestamp=.+', details, re.M):
        raise ValueError('Executable code needs Hardened Runtime and a secure timestamp')
    raw = run('codesign', '--display', '--entitlements', '-', '--xml', path)
    if raw.strip() and plistlib.loads(raw).get('com.apple.security.get-task-allow'):
        raise ValueError('Debug signing entitlement is forbidden')


def notarize(path, auth):
    response = json.loads(run('xcrun', 'notarytool', 'submit', path, *auth, '--wait', '--timeout', '30m', '--output-format', 'json'))
    if response.get('status') != 'Accepted' or not re.fullmatch(r'[a-fA-F0-9-]{36}', response.get('id', '')):
        raise ValueError('Apple did not accept this notarization submission')
    return response['id']


def staple(path):
    run('xcrun', 'stapler', 'staple', path)
    run('xcrun', 'stapler', 'validate', path)


# Debug-only live typing self-test; a release app must never contain it.
DEBUG_ONLY_MARKERS = (b'--pflow-inline-selftest',)


def require_no_debug_entry(app):
    # Debug builds keep their code in a separate dylib beside the executable.
    for path in sorted((Path(app) / 'Contents/MacOS').iterdir()):
        if path.is_file() and any(marker in path.read_bytes() for marker in DEBUG_ONLY_MARKERS):
            raise ValueError('Release app contains a debug-only entry point')


def package(app, dist, *, testing=False, env=None):
    env = os.environ if env is None else env
    signing = None if testing else preflight(env)
    if not testing:
        run('git', 'diff', '--quiet')
        run('git', 'diff', '--cached', '--quiet')
    commit = run('git', 'rev-parse', 'HEAD').decode().strip() if signing else ''
    if app is None:
        if testing:
            app = ROOT / 'build/Build/Products/Release/pFlow.app'
        else:
            run('xcodegen', 'generate')
            run('xcodebuild', '-project', 'Yap.xcodeproj', '-scheme', 'Yap', '-configuration', 'Release',
                '-destination', 'platform=macOS', '-derivedDataPath', 'build', 'CODE_SIGNING_ALLOWED=NO',
                'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', f'PFLOW_DEVELOPER_TEAM={signing[0]}', 'clean', 'build')
            app = ROOT / 'build/Build/Products/Release/pFlow.app'
    app = Path(app).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = info.get('CFBundleShortVersionString', '')
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version) or any(int(x) > 2147483647 for x in version.split('.')):
        raise ValueError('Invalid app version')
    # Keep the bundle ID for existing data; the executable is the name macOS shows.
    if info.get('CFBundleIdentifier') != 'com.pesh.Yap' or info.get('CFBundleExecutable') != 'pFlow':
        raise ValueError('Unexpected app identity')
    executable = app / 'Contents/MacOS/pFlow'
    if executable.is_symlink() or not executable.is_file():
        raise ValueError('Unexpected app executable')
    run('lipo', '-verify_arch', 'arm64', executable)
    require_no_debug_entry(app)
    # Public 0.3.5 updaters require this suffix, even for notarized downloads.
    name = f'pFlow-Mac-{version}-testing.dmg'
    dist = Path(dist); dist.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='pflow-package-') as temporary:
        work = Path(temporary)
        stage = work / 'stage'; stage.mkdir()
        final_app = stage / 'pFlow by Pesh.app'
        run('ditto', app, final_app)
        if signing:
            team, identity, keychain, auth = signing
            if info.get('PFLOWUpdateTeamID') != team:
                raise ValueError('Build the app with the approved PFLOW_DEVELOPER_TEAM')
            entitlements = Path(env.get('PFLOW_ENTITLEMENTS_FILE', str(ROOT / 'Sources/Yap.entitlements')))
            policy = plistlib.loads(entitlements.read_bytes())
            if 'com.apple.security.get-task-allow' in policy:
                raise ValueError('Debug signing entitlement is forbidden')
            codes = code_paths(final_app)
            for code in codes:
                run('codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity,
                    *(['--keychain', keychain] if keychain else []),
                    *(['--entitlements', entitlements] if code == final_app else []), code)
            for code in codes:
                verify_code(code, team)
            archive = work / 'app.zip'
            run('ditto', '-c', '-k', '--keepParent', final_app, archive)
            app_submission = notarize(archive, auth)
            staple(final_app)
            run('spctl', '--assess', '--type', 'execute', final_app)
        else:
            run('codesign', '--verify', '--deep', '--strict', final_app)
        shutil.copyfile(ROOT / 'LICENSE', stage / 'LICENSE.txt')
        (stage / 'Applications').symlink_to('/Applications')
        dmg = work / name
        run('hdiutil', 'create', '-volname', 'pFlow by Pesh', '-srcfolder', stage, '-format', 'UDZO', dmg)
        run('hdiutil', 'verify', dmg)
        if signing:
            run('codesign', '--force', '--timestamp', '--sign', identity, *(['--keychain', keychain] if keychain else []), dmg)
            run('codesign', '--verify', '--strict', dmg)
            dmg_submission = notarize(dmg, auth)
            staple(dmg)
            run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', dmg)
            mount = work / 'mount'; mount.mkdir()
            run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, dmg)
            try:
                shipped = mount / 'pFlow by Pesh.app'
                verify_code(shipped, team)
                run('xcrun', 'stapler', 'validate', shipped)
                run('spctl', '--assess', '--type', 'execute', shipped)
            finally:
                run('hdiutil', 'detach', mount)
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        receipt = dist / (name + '.trusted.json')
        receipt.unlink(missing_ok=True)
        shutil.copyfile(dmg, dist / name)
        (dist / (name + '.sha256')).write_text(f'{digest}  {name}\n')
        if signing:
            receipt.write_text(json.dumps(dict(schema=1, platform='mac-arm64', version=version, file=name,
                bytes=dmg.stat().st_size, sha256=digest, teamID=team, sourceCommit=commit,
                appNotarization=dict(id=app_submission, status='Accepted'),
                dmgNotarization=dict(id=dmg_submission, status='Accepted'),
                appStapled=True, dmgStapled=True, gatekeeper=True), indent=2, sort_keys=True) + '\n')
    print('Trusted candidate prepared; clean-Mac installation checks remain.' if signing else 'Development DMG only; no trusted-release receipt.')
    return dist / name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--testing', action='store_true')
    parser.add_argument('testing_app', nargs='?', type=Path)
    parser.add_argument('--app', type=Path, help='Already built production app with the approved team embedded')
    args = parser.parse_args()
    if args.testing_app and not args.testing or args.app and args.testing:
        parser.error('Use --testing [built-app], or --app built-app for production')
    try:
        package(args.testing_app if args.testing else args.app, ROOT / 'dist', testing=args.testing)
    except (ValueError, RuntimeError, OSError) as error:
        raise SystemExit(str(error)) from None


if __name__ == '__main__':
    main()
