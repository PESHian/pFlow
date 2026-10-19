"""Assemble architecture-tested payloads; never compile or copy user data here."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import zipfile
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('artifacts', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
scripts = Path(__file__).resolve().parent
version = ET.parse(scripts.parent / 'PFlow.App/PFlow.App.csproj').findtext('.//Version')
assert version and re.fullmatch(r'\d+\.\d+\.\d+', version)
stage = args.output / f'pFlow-Windows-Universal-{version}-testing'
stage.mkdir(parents=True, exist_ok=False)
machines = {'x64': 0x8664, 'x86': 0x14c, 'arm64': 0xaa64}
system_dlls = set('kernel32.dll advapi32.dll user32.dll ws2_32.dll bcrypt.dll ntdll.dll msvcrt.dll ucrtbase.dll shell32.dll ole32.dll oleaut32.dll shlwapi.dll version.dll crypt32.dll psapi.dll'.split())


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def pe(path):
    data = path.read_bytes()
    assert data[:2] == b'MZ', path
    start = struct.unpack_from('<I', data, 60)[0]
    assert data[start:start + 4] == b'PE\0\0', path
    optional = start + 24
    directories = optional + (112 if struct.unpack_from('<H', data, optional)[0] == 0x20b else 96)
    table = optional + struct.unpack_from('<H', data, start + 20)[0]
    sections = struct.unpack_from('<H', data, start + 6)[0]

    def offset(rva):
        for i in range(sections):
            _, address, size, pointer = struct.unpack_from('<IIII', data, table + 40 * i + 8)
            if address <= rva < address + size:
                return pointer + rva - address
        raise ValueError('Unmapped PE address')

    imports = []
    rva, size = struct.unpack_from('<II', data, directories + 8)
    if rva and size:
        cursor = offset(rva)
        while any(data[cursor:cursor + 20]):
            pointer = offset(struct.unpack_from('<I', data, cursor + 12)[0])
            imports.append(data[pointer:data.index(0, pointer)].decode('ascii').lower())
            cursor += 20
    rva, size = struct.unpack_from('<II', data, directories + 13 * 8)
    if rva and size:
        cursor = offset(rva)
        image_base = struct.unpack_from('<Q' if directories == optional + 112 else '<I', data, optional + (24 if directories == optional + 112 else 28))[0]
        while any(data[cursor:cursor + 32]):
            attributes, name = struct.unpack_from('<II', data, cursor)
            pointer = offset(name if attributes & 1 else name - image_base)
            imports.append(data[pointer:data.index(0, pointer)].decode('ascii').lower())
            cursor += 32
    return struct.unpack_from('<H', data, start + 4)[0], imports


for architecture, machine in machines.items():
    source = args.artifacts / 'payloads' / ('win-' + architecture)
    dest = stage / 'payloads' / source.name
    shutil.copytree(source, dest)
    for name in ('pFlow.exe', 'engine/whisper-cli.exe', 'engine/pflow-whisper.exe'):
        assert pe(dest / name)[0] == machine, name
    for name in ('install-windows.ps1', 'WindowsArchitecture.ps1'):
        shutil.copyfile(scripts / name, dest / name)
    assert len(list((dest / 'Licenses').glob('*'))) >= 9
    # Microsoft's ARM64 CRT folder also carries an unused ARM64EC/x64 companion.
    # Never relax native architecture validation to include that companion.
    companion = dest / 'text-engine/vcruntime140_1.dll'
    if architecture == 'arm64' and companion.exists() and pe(companion)[0] == 0x8664:
        for other in companion.parent.iterdir():
            if other == companion or other.suffix.lower() not in ('.exe', '.dll'):
                continue
            assert 'vcruntime140_1.dll' not in pe(other)[1], other.name
            raw = other.read_bytes()
            assert b'vcruntime140_1.dll' not in raw.lower() and 'vcruntime140_1.dll'.encode('utf-16le') not in raw.lower(), other.name
        companion.unlink()
    if architecture == 'x86':
        assert not (dest / 'text-engine').exists()
    for directory in ('engine', 'text-engine'):
        folder = dest / directory
        if not folder.exists():
            continue
        available = {p.name.lower() for p in folder.iterdir()}
        for path in folder.iterdir():
            if path.suffix.lower() not in ('.dll', '.exe'):
                continue
            actual, imports = pe(path)
            assert actual == machine, path.name
            for dependency in imports:
                assert dependency in system_dlls or dependency.startswith(('api-ms-win-', 'ext-ms-win-')) or dependency in available, (path.name, dependency)
    for name in ('pFlow.dll', 'PFlow.Core.dll'):
        assert sha(dest / name) == sha(source / name), 'Do not change tested application assemblies'

shutil.copytree(args.artifacts / 'shared', stage / 'shared')
model = stage / 'shared/models/ggml-small.bin'
assert model.stat().st_size == 487601967
assert sha(model) == '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b'
for name in ('Install.cmd', 'install-universal.ps1', 'WindowsArchitecture.ps1'):
    shutil.copyfile(scripts / name, stage / name)
shutil.copyfile(scripts.parent / 'INSTALLATION.txt', stage / 'INSTALLATION.txt')

entries = []
for path in sorted(stage.rglob('*')):
    if not path.is_file():
        continue
    name = path.relative_to(stage).as_posix()
    assert not path.suffix.lower() in ('.pdb', '.wav', '.gguf', '.cs', '.cpp', '.sqlite', '.jsonl'), name
    assert path.name.lower() not in ('settings.json', 'history.json', 'last-processing-times.json'), name
    if path != model:
        data = path.read_bytes()
        for raw in (data, data[::2], data[1::2]):
            assert not re.search(rb'(?:/home/(?!runner/)[^/\x00\r\n ]+|/Users/[^/\x00\r\n ]+|[a-z]:[\\/]Users[\\/](?!runneradmin[\\/])[^\\/\x00\r\n ]+)', raw, re.I), name
    entries.append({'path': name, 'sha256': sha(path)})
(stage / 'package-hashes.json').write_text(json.dumps(entries, indent=2) + '\n')
archive = args.output / (stage.name + '.zip')
with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=1) as z:
    for path in sorted(stage.rglob('*')):
        if path.is_file():
            z.write(path, path.relative_to(stage).as_posix())
assert archive.stat().st_size < 2 * 1024 ** 3
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    assert len(z.namelist()) == len(set(z.namelist()))
    for entry in entries:
        assert hashlib.sha256(z.read(entry['path'])).hexdigest() == entry['sha256'], entry['path']
digest = sha(archive)
archive.with_suffix('.zip.sha256').write_text(digest + '  ' + archive.name + '\n')
print(json.dumps({'file': archive.name, 'bytes': archive.stat().st_size, 'sha256': digest,
                  'architectures': list(machines), 'entries': len(entries) + 1,
                  'unchanged_tested_assemblies': True, 'native_dependency_check': True,
                  'full_crc_and_manifest': True, 'owner_paths_absent': True}))
