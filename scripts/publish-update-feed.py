"""Publish authenticated update metadata after GitHub binary releases.
Uses only Python's standard library and OpenSSL. No downloaded code is run.
"""
import argparse, base64, hashlib, json, os, re, subprocess, tempfile
from pathlib import Path
from urllib.request import Request, urlopen
ROOT=Path(__file__).resolve().parent.parent
REPO='PESHian/pFlow'
def command(args, data=None):
    return subprocess.run(args,input=data,stdout=subprocess.PIPE,check=True).stdout
def version(value):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)',value):raise ValueError('Invalid release version')
    parts=tuple(map(int,value.split('.')))
    if any(x>2147483647 for x in parts):raise ValueError('Invalid release version')
    return parts
def validate_mac_receipt(receipt, asset, expected_team):
    if not re.fullmatch(r'[A-Z0-9]{10}',expected_team):raise ValueError('Configure the approved Mac developer team before publishing Mac updates')
    if any(receipt.get(k)!=v for k,v in dict(schema=1,platform='mac-arm64',file=asset['name'],bytes=asset['size'],sha256=asset['digest'][7:],teamID=expected_team).items()):
        raise ValueError('Trusted Mac receipt does not match this release asset and team')
    if asset['name']!=f"pFlow-Mac-{receipt.get('version')}-testing.dmg":raise ValueError('Trusted Mac receipt version mismatch')
    if any(receipt.get(k) is not True for k in ['appStapled','dmgStapled','gatekeeper']):raise ValueError('Mac trust checks did not pass')
    for key in ['appNotarization','dmgNotarization']:
        result=receipt.get(key,{})
        if result.get('status')!='Accepted' or not re.fullmatch(r'[a-fA-F0-9-]{36}',result.get('id','')):raise ValueError('Mac notarization was not accepted')
    if not re.fullmatch(r'[a-f0-9]{40}',receipt.get('sourceCommit','')):raise ValueError('Missing Mac source commit')

def mac_receipts(release, previous, expected_team):
    receipts={}
    for asset in release['assets']:
        match=re.fullmatch(r'pFlow-Mac-(\d+\.\d+\.\d+)-testing\.dmg',asset['name'])
        if not match:continue
        old=previous.get('targets',{}).get('mac-arm64')
        if old and version(old['version'])>=version(match[1]):continue
        name=asset['name']+'.trusted.json'
        matches=[a for a in release['assets'] if a['name']==name]
        if len(matches)!=1:raise ValueError('New Mac downloads require an attested trusted-release receipt')
        receipt_asset=matches[0]
        url=f"https://github.com/{REPO}/releases/download/{release['tag_name']}/{name}"
        if receipt_asset['browser_download_url']!=url or not 0<receipt_asset['size']<=16384:raise ValueError('Invalid Mac receipt asset')
        with urlopen(Request(url,headers={'User-Agent':'pFlow-release'}),timeout=30) as response:
            data=response.read(16385)
        if len(data)!=receipt_asset['size'] or receipt_asset.get('digest')!='sha256:'+hashlib.sha256(data).hexdigest():raise ValueError('Mac receipt hash mismatch')
        receipt=json.loads(data)
        validate_mac_receipt(receipt,asset,expected_team)
        with tempfile.TemporaryDirectory(prefix='pflow-receipt-') as tmp:
            file=Path(tmp)/name;file.write_bytes(data)
            command(['gh','attestation','verify',str(file),'--repo',REPO,
                     '--signer-workflow',REPO+'/.github/workflows/mac-trusted-release.yml',
                     '--source-ref','refs/heads/main','--source-digest',receipt['sourceCommit'],'--deny-self-hosted-runners'])
        receipts[asset['name']]=receipt
    return receipts

def merge(release, previous, receipts=None, expected_team=''):
    if release.get('draft'):raise ValueError('Publish the binary release before its feed')
    tag=release['tag_name']
    if not re.fullmatch(r'[A-Za-z0-9._-]{1,100}',tag):raise ValueError('Invalid release tag')
    targets=dict(previous.get('targets',{})); found=0
    for asset in release['assets']:
        name=asset['name']
        match=re.fullmatch(r'pFlow-Windows-(x64|x86|arm64)-(\d+\.\d+\.\d+)-update\.zip',name)
        mac=re.fullmatch(r'pFlow-Mac-(\d+\.\d+\.\d+)-testing\.dmg',name)
        if match: platform='windows-'+match[1];v=match[2]
        elif mac:platform='mac-arm64';v=mac[1]
        else:continue
        version(v); digest=asset.get('digest') or ''
        if not re.fullmatch('sha256:[0-9a-f]{64}',digest):raise ValueError('GitHub asset SHA-256 digest is missing')
        url=f'https://github.com/{REPO}/releases/download/{tag}/{name}'
        if asset['browser_download_url']!=url or not 0<asset['size']<=536870912:raise ValueError('Invalid release asset URL or size')
        candidate=dict(version=v,url=url,bytes=asset['size'],sha256=digest[7:])
        old=targets.get(platform)
        if old and version(old['version'])>version(v):continue
        if old and old['version']==v:
            if old['sha256']!=candidate['sha256']:raise ValueError('Changed binary must use a new version')
            continue
        if mac:
            if name not in (receipts or {}):raise ValueError('New Mac downloads require an attested trusted-release receipt')
            validate_mac_receipt(receipts[name],asset,expected_team)
        targets[platform]=candidate;found+=1
    if not targets:raise ValueError('No supported update assets')
    return dict(schema=1,targets=dict(sorted(targets.items()))),found

def main():
    p=argparse.ArgumentParser();p.add_argument('tag');p.add_argument('--key',type=Path,required=True);p.add_argument('--commit',action='store_true');a=p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9._-]{1,100}',a.tag):raise ValueError('Invalid release tag')
    release=json.loads(command(['gh','api',f'repos/{REPO}/releases/tags/{a.tag}']))
    head=json.loads(command(['gh','api',f'repos/{REPO}/git/ref/heads/main']))['object']['sha'] if a.commit else None
    if a.commit:
        previous_data=base64.b64decode(json.loads(command(['gh','api',f'repos/{REPO}/contents/updates/feed.json?ref={head}']))['content'])
        previous_signature=base64.b64decode(json.loads(command(['gh','api',f'repos/{REPO}/contents/updates/feed.json.sig?ref={head}']))['content'])
    else:
        previous_data=(ROOT/'updates/feed.json').read_bytes();previous_signature=(ROOT/'updates/feed.json.sig').read_bytes()
    if len(previous_data)>65536 or len(previous_signature)>4096:raise ValueError('Invalid existing feed')
    with tempfile.TemporaryDirectory(prefix='pflow-verify-') as tmp:
        sigfile=Path(tmp)/'signature';sigfile.write_bytes(base64.b64decode(previous_signature.strip(),validate=True))
        command(['openssl','dgst','-sha256','-verify',str(ROOT/'updates/public-key.pem'),'-signature',str(sigfile)],previous_data)
    previous=json.loads(previous_data)
    if previous.get('schema')!=1:raise ValueError('Unsupported existing feed')
    team=os.environ.get('PFLOW_DEVELOPER_TEAM','')
    receipts=mac_receipts(release,previous,team)
    feed,found=merge(release,previous,receipts,team)
    if not found:print('No newer update assets; existing feed kept.');return
    data=(json.dumps(feed,indent=2,sort_keys=True)+'\n').encode()
    public=command(['openssl','pkey','-in',str(a.key),'-pubout','-outform','DER'])
    expected=command(['openssl','pkey','-pubin','-in',str(ROOT/'updates/public-key.pem'),'-outform','DER'])
    if public!=expected:raise ValueError('Wrong update signing key')
    signature=base64.b64encode(command(['openssl','dgst','-sha256','-sign',str(a.key)],data))+b'\n'
    if not a.commit:
        (ROOT/'updates/feed.json').write_bytes(data);(ROOT/'updates/feed.json.sig').write_bytes(signature);return
    # One atomic Git commit for both files prevents a half-published feed in git.
    commit=json.loads(command(['gh','api',f'repos/{REPO}/git/commits/{head}']))
    entries=[]
    for name,content in [('feed.json',data),('feed.json.sig',signature)]:
        blob=json.loads(command(['gh','api','--method','POST',f'repos/{REPO}/git/blobs','--input','-'],json.dumps({'content':base64.b64encode(content).decode(),'encoding':'base64'}).encode()))
        entries.append(dict(path='updates/'+name,mode='100644',type='blob',sha=blob['sha']))
    tree=json.loads(command(['gh','api','--method','POST',f'repos/{REPO}/git/trees','--input','-'],json.dumps(dict(base_tree=commit['tree']['sha'],tree=entries)).encode()))
    new=json.loads(command(['gh','api','--method','POST',f'repos/{REPO}/git/commits','--input','-'],json.dumps(dict(message='Publish signed pFlow update feed',tree=tree['sha'],parents=[head])).encode()))
    command(['gh','api','--method','PATCH',f'repos/{REPO}/git/refs/heads/main','--input','-'],json.dumps(dict(sha=new['sha'],force=False)).encode())
    print('Published signed update feed for '+str(found)+' platform(s).')
if __name__=='__main__':main()
