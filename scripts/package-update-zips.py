"""Package tested native Windows payloads for updates, without model weights."""
import argparse,hashlib,json,re,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('payloads',type=Path);p.add_argument('output',type=Path);p.add_argument('--version',required=True);a=p.parse_args()
assert re.fullmatch(r'\d+\.\d+\.\d+',a.version)
a.output.mkdir(parents=True,exist_ok=True)
for arch in ('x64','x86','arm64'):
    root=a.payloads/('win-'+arch)
    assert (root/'pFlow.exe').is_file() and (root/'Update/update-install.ps1').is_file()
    assert not (root/'models').exists(),'Model changes require a full installer'
    paths=sorted(x for x in root.rglob('*') if x.is_file())
    assert all(x.suffix.lower()!='.pdb' for x in paths)
    manifest=[]
    for file in paths:
        with file.open('rb') as stream: digest=hashlib.file_digest(stream,'sha256').hexdigest()
        manifest.append(dict(path=file.relative_to(root).as_posix(),sha256=digest))
    archive=a.output/f'pFlow-Windows-{arch}-{a.version}-update.zip'
    with zipfile.ZipFile(archive,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=1) as z:
        for file in paths:z.write(file,file.relative_to(root).as_posix())
        z.writestr('package-hashes.json',json.dumps(manifest,indent=2)+'\n')
    assert archive.stat().st_size<=536870912
    with archive.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
    archive.with_suffix('.zip.sha256').write_text(digest+'  '+archive.name+'\n')
    print(archive.name,archive.stat().st_size,digest)
