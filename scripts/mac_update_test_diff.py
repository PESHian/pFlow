"""Prove the update-test DMG is the release DMG with only its version and signatures changed.

The update-test DMG is the same source built with MARKETING_VERSION set lower (it reads 0.3.16),
so a person running it is offered the real release. Run this after both DMGs are packaged, on the
Mac, before either is served:

    python3 scripts/mac_update_test_diff.py pFlow-Mac-0.3.18-testing.dmg pFlow-Mac-0.3.18-update-test.dmg

It mounts both read-only under a private temporary folder (never in /Volumes, never opened in
Finder), never launches or registers either app, and detaches both when done. It passes (exit 0)
only when:
  1. both volumes hold the same paths, with the same kinds, permission bits and symlink targets;
  2. every file is byte for byte the same, except
     - property lists (*.plist), which may differ only in CFBundleShortVersionString and
       CFBundleVersion, and the main app's CFBundleShortVersionString must differ;
     - Mach-O files, which may differ only in their code signature: copies of both, with the
       signature removed by `codesign --remove-signature`, must be byte for byte the same;
     - _CodeSignature/CodeResources, which is the signature over the files above;
  3. `codesign --verify --deep --strict` passes on both apps.
Record its last line in the ledger.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile

APP = 'pFlow by Pesh.app'
VERSION_KEYS = ('CFBundleShortVersionString', 'CFBundleVersion')
MACHO = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def entries(root):
    """Every path under `root`, relative, with what it is (symlinks are not followed)."""
    found = {}
    for folder, dirs, files in os.walk(root):
        for name in dirs + files:
            path = Path(folder) / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                kind = ('link', os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                kind = ('dir', None)
            else:
                kind = ('file', None)
            found[str(path.relative_to(root))] = (kind, stat.S_IMODE(info.st_mode))
    return found


def is_macho(path):
    with open(path, 'rb') as f:
        return f.read(4) in MACHO


def strip_signature(path, scratch):
    """A copy of the Mach-O at `path` without its code signature, as bytes."""
    copy = Path(scratch) / f'unsigned-{os.getpid()}-{abs(hash(str(path)))}'
    shutil.copyfile(path, copy)
    try:
        subprocess.run(['codesign', '--remove-signature', str(copy)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return copy.read_bytes()
    finally:
        copy.unlink(missing_ok=True)


def compare(release, test, strip=strip_signature):
    """Compares two volume trees. Returns (files compared, allowed differences, unexpected differences)."""
    a, b = entries(release), entries(test)
    allowed, unexpected = [], []
    for path in sorted(set(a) | set(b)):
        if path not in a or path not in b:
            unexpected.append(f'{path}: only in the {"update-test" if path in b else "release"} DMG')
        elif a[path] != b[path]:
            unexpected.append(f'{path}: kind, link target or permissions differ')
    compared = 0
    with tempfile.TemporaryDirectory(prefix='pflow-ut-diff-') as scratch:
        for path in sorted(p for p in set(a) & set(b) if a[p][0][0] == 'file' and a[p] == b[p]):
            compared += 1
            left, right = Path(release) / path, Path(test) / path
            one, two = left.read_bytes(), right.read_bytes()
            if one == two:
                continue
            if path.endswith('_CodeSignature/CodeResources'):
                allowed.append(f'{path}: signature')
            elif path.endswith('.plist'):
                try:
                    p1, p2 = plistlib.loads(one), plistlib.loads(two)
                except Exception:
                    unexpected.append(f'{path}: not a readable property list')
                    continue
                if not (isinstance(p1, dict) and isinstance(p2, dict)):
                    unexpected.append(f'{path}: property list differs')
                    continue
                changed = sorted(k for k in set(p1) | set(p2) if p1.get(k) != p2.get(k))
                other = [k for k in changed if k not in VERSION_KEYS]
                if other:
                    unexpected.append(f'{path}: property list differs in {", ".join(other)}')
                else:
                    allowed.append(f'{path}: {", ".join(f"{k} {p1.get(k)} -> {p2.get(k)}" for k in changed)}')
            elif is_macho(left) and is_macho(right):
                if strip(left, scratch) == strip(right, scratch):
                    allowed.append(f'{path}: code signature only')
                else:
                    unexpected.append(f'{path}: code differs, not only its signature')
            else:
                unexpected.append(f'{path}: bytes differ')
    main = f'{APP}/Contents/Info.plist'
    if main in a and main in b:
        versions = [plistlib.loads((Path(root) / main).read_bytes()).get('CFBundleShortVersionString') for root in (release, test)]
        if versions[0] == versions[1]:
            unexpected.append(f'{main}: both read {versions[0]}, the update-test copy must read an older version')
    else:
        unexpected.append(f'{main}: missing')
    return compared, allowed, unexpected


def attach(dmg, mount):
    subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(dmg)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def detach(mount):
    subprocess.run(['hdiutil', 'detach', str(mount)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('release_dmg', type=Path)
    parser.add_argument('update_test_dmg', type=Path)
    args = parser.parse_args(argv)
    with tempfile.TemporaryDirectory(prefix='pflow-ut-mounts-') as folder:
        mounts = [Path(folder) / 'release', Path(folder) / 'update-test']
        attached = []
        try:
            for dmg, mount in zip((args.release_dmg, args.update_test_dmg), mounts):
                mount.mkdir()
                attach(dmg, mount)
                attached.append(mount)
            compared, allowed, unexpected = compare(*mounts)
            for mount in mounts:
                signed = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(mount / APP)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                if not signed:
                    unexpected.append(f'{mount.name}: codesign --verify --deep --strict failed')
        finally:
            for mount in attached:
                detach(mount)
    for line in allowed:
        print('allowed   ', line)
    for line in unexpected:
        print('UNEXPECTED', line)
    verdict = 'PASS' if not unexpected else 'FAIL'
    print(f'{verdict}: {compared} files compared, {len(allowed)} differ only in version or signature, {len(unexpected)} unexpected')
    return 0 if not unexpected else 1


if __name__ == '__main__':
    sys.exit(main())
