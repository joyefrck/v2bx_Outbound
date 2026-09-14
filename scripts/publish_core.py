#!/usr/bin/env python3
"""Publish only a complete, tested, same-commit pair of native Linux artifacts."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root=Path(__file__).resolve().parents[1]
dist=Path(sys.argv[1]).resolve()
lock=json.loads((root/'runtime/cores.lock.json').read_text())
if os.environ.get('GITHUB_ACTIONS')!='true' or os.environ.get('GITHUB_EVENT_NAME')!='workflow_dispatch':
    raise SystemExit('Publication is available only through the explicitly dispatched verified workflow.')
revision=os.environ['GITHUB_SHA']
if not os.environ.get('CORE_RELEASE_SIGNING_KEY'):raise SystemExit('CORE_RELEASE_SIGNING_KEY is not configured.')
files=[]
for arch in ['amd64','arm64']:
    manifest=dist/f'manifest-linux-{arch}.json';m=json.loads(manifest.read_text())
    if m.get('source_state')!='commit':raise SystemExit('Working-tree artifacts cannot be published.')
    if (m['tag'],m['platform'],m['source_revision'],m['cores'],m['patch_index_sha256'])!=(lock['tag'],'linux-'+arch,revision,lock['modules'],lock['patch_index_sha256']):raise SystemExit('Unvalidated or mismatched provenance.')
    for field,expected_name in [('asset',f'V2bX-linux-{arch}.zip'),('source_asset',f'source-linux-{arch}.tar.gz')]:
        if m[field]!=expected_name:raise SystemExit('Unexpected artifact name.')
        file=dist/expected_name;checksum=m['sha256' if field=='asset' else 'source_sha256']
        if hashlib.sha256(file.read_bytes()).hexdigest()!=checksum:raise SystemExit('Artifact checksum mismatch.')
        files.append(file)
    files.append(manifest)
with tempfile.TemporaryDirectory(prefix='v2bx-sign-') as temp:
    key=Path(temp)/'key.pem';key.write_text(os.environ.pop('CORE_RELEASE_SIGNING_KEY'));key.chmod(0o600)
    public=Path(temp)/'public.pem'
    public.write_bytes(subprocess.check_output(['bash','-c','source "$1"; m_core_public_key','public-key',str(root/'v2bx-manager.sh')]))
    for arch in ['amd64','arm64']:
        manifest=dist/f'manifest-linux-{arch}.json';signature=manifest.with_suffix('.json.sig')
        subprocess.run(['openssl','dgst','-sha256','-sign',str(key),'-out',str(signature),str(manifest)],check=True)
        subprocess.run(['openssl','dgst','-sha256','-verify',str(public),'-signature',str(signature),str(manifest)],check=True)
        files.append(signature)
# A fresh draft is invisible to update discovery until every asset is uploaded.
notes=dist/'release-notes.md'
notes.write_text('Official-source integrated V2bX build.\n\n'+ '\n'.join(f'- {name}: {core["tag"]} ({core["version"]})' for name,core in lock['modules'].items())+'\n\nIncludes reviewed compatibility patches; see cores.lock.json and the corresponding source archives. Native amd64/arm64 builds, protocol lifecycles, traffic, concurrency, SOCKS egress and manager transaction tests passed in the producing workflow. Existing Geo files are preserved during upgrades.\n')
repo='joyefrck/v2bx_Outbound';tag=lock['tag']
subprocess.run(['gh','release','create',tag,'--repo',repo,'--target',revision,'--draft','--title',tag,'--notes-file',str(notes)],check=True)
subprocess.run(['gh','release','upload',tag,'--repo',repo,*map(str,files)],check=True)
subprocess.run(['gh','release','edit',tag,'--repo',repo,'--draft=false','--latest=false'],check=True)
