#!/usr/bin/env python3
"""One-time signing bootstrap. Private key goes directly to Actions, never to Git."""
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
source=root/'src/manager/core-release.sh'
text=source.read_text()
if '__CORE_PUBLIC_KEY__' not in text:raise SystemExit('Signing already initialized. Do not rotate keys without a backward-compatible trust-key migration.')
with tempfile.TemporaryDirectory(prefix='v2bx-signing-bootstrap-') as tmp:
    key=Path(tmp)/'private.pem';public=Path(tmp)/'public.pem'
    subprocess.run(['openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:3072','-out',str(key)],check=True,capture_output=True)
    key.chmod(0o600)
    subprocess.run(['openssl','pkey','-in',str(key),'-pubout','-out',str(public)],check=True,capture_output=True)
    with key.open('rb') as secret:
        subprocess.run(['gh','secret','set','CORE_RELEASE_SIGNING_KEY','--repo','joyefrck/v2bx_Outbound'],stdin=secret,check=True)
    source.write_text(text.replace('__CORE_PUBLIC_KEY__',public.read_text().strip()))
subprocess.run(['bash','build.sh'],cwd=root,check=True)
print('Signing key configured in GitHub Actions; only the public key is included in the manager.')
