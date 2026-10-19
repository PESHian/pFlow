"""Sign a release feed locally. The private key stays outside the repository.
Requires Python cryptography. Never put the private key into a release asset.
"""
import argparse, base64, json
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
p=argparse.ArgumentParser()
p.add_argument('feed',type=Path)
p.add_argument('--key',type=Path,required=True)
a=p.parse_args()
data=a.feed.read_bytes()
assert len(data)<=65536 and json.loads(data)['schema']==1
key=serialization.load_pem_private_key(a.key.read_bytes(),None)
assert isinstance(key,ec.EllipticCurvePrivateKey) and isinstance(key.curve,ec.SECP256R1)
public=serialization.load_pem_public_key((Path(__file__).resolve().parent.parent/'updates/public-key.pem').read_bytes())
assert key.public_key().public_numbers()==public.public_numbers(),'Wrong update signing key'
a.feed.with_suffix(a.feed.suffix+'.sig').write_bytes(base64.b64encode(key.sign(data,ec.ECDSA(hashes.SHA256())))+b'\n')
