#!/usr/bin/env python3
"""Build a locked integrated runtime and package its measured metadata.

Release jobs run this natively on each target; cross builds use --build-only.
No latest dependency resolution happens here.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'runtime'
sys.path.insert(0, str(ROOT / 'scripts'))
from core_overlay import generate
from core_sources import archive

def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def read_lock():
    lock = json.loads((RUNTIME/'cores.lock.json').read_text())
    if sha(RUNTIME/'patches/index.json') != lock['patch_index_sha256']:
        raise ValueError('patch index differs from reviewed lock')
    for patch in json.loads((RUNTIME/'patches/index.json').read_text()):
        if sha(RUNTIME/'patches'/patch['replacement']) != patch['sha256']:
            raise ValueError('patch differs from reviewed lock: '+patch['replacement'])
    return lock

def build(out, arch, target_os, build_only):
    lock=read_lock(); out=out.resolve(); out.mkdir(parents=True,exist_ok=True)
    env=dict(os.environ,GOTOOLCHAIN=lock['go'],GOEXPERIMENT='jsonv2',CGO_ENABLED='0',GOOS=target_os,GOARCH=arch)
    os.environ['GOTOOLCHAIN']=lock['go']
    if subprocess.check_output(['go','env','GOVERSION'],env=env,text=True).strip()!=lock['go']:raise ValueError('toolchain mismatch')
    with tempfile.TemporaryDirectory(prefix='v2bx-build-') as td:
        work=Path(td); source=work/'source'
        shutil.copytree(RUNTIME,source,ignore=shutil.ignore_patterns('__pycache__'))
        mod=generate(source/'patched.json')
        # Relative replacements keep Go's embedded build metadata independent of
        # the temporary checkout path, while still exposing every local patch.
        patch_modules={p['module'] for p in json.loads((RUNTIME/'patches/index.json').read_text())}
        for module in sorted(patch_modules):
            subprocess.run(['go','mod','edit','-modfile='+str(mod),'-replace='+module.split('@')[0]+'=./patched.deps/'+module.replace('/','_')],cwd=source,env=env,check=True)
        # Verify every locked core matches the actual module graph, including the private patch bases.
        graph=json.loads(subprocess.check_output(['go','mod','edit','-json','-modfile='+str(mod)],cwd=source,env=env,text=True))
        requires={m['Path']:m['Version'] for m in graph['Require']}
        for core in lock['modules'].values():
            if requires.get(core['path'])!=core['version']:raise ValueError('module lock mismatch: '+core['path'])
            info=json.loads(subprocess.check_output(['go','mod','download','-json',core['path']+'@'+core['version']],cwd=source,env=env,text=True))
            if info['Sum']!=core['sum']:raise ValueError('module checksum mismatch')
        revision=os.environ.get('GITHUB_SHA','')
        if not revision: revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        if not re.fullmatch('[0-9a-f]{40}',revision):raise ValueError('invalid revision')
        source_state='working-tree'
        if os.environ.get('GITHUB_ACTIONS')=='true':
            head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
            status=subprocess.check_output(['git','status','--porcelain','--untracked-files=normal'],cwd=ROOT,text=True).strip()
            if head!=revision or status:raise ValueError('release builds require the clean checked-out commit')
            source_state='commit'
        ld=f'-s -w -X github.com/InazumaV/V2bX/cmd.sourceState={source_state} -X github.com/InazumaV/V2bX/cmd.version={lock["version"]} -X github.com/InazumaV/V2bX/cmd.sourceRevision={revision} -X github.com/InazumaV/V2bX/cmd.patchDigest={lock["patch_index_sha256"]}'
        binary=out/'V2bX'
        subprocess.run(['go','build','-trimpath','-buildvcs=false','-mod=readonly','-modfile='+str(mod),'-tags',' '.join(lock['tags']),'-ldflags',ld,'-o',str(binary),'.'],cwd=source,env=env,check=True)
        if build_only:return
        archive(source,mod,lock['tags'],env,out/f'source-linux-{arch}.tar.gz',ROOT)
        info=json.loads(subprocess.check_output([str(binary),'build-info'],text=True))
        if (info['os'],info['arch'])!=(target_os,arch):raise ValueError('platform mismatch')
        for name,core in lock['modules'].items():
            actual=info['modules'][name]
            if (actual['path'],actual['version'])!=(core['path'],core['version']):raise ValueError('compiled core mismatch')
        (out/'build-info.json').write_text(json.dumps(info,sort_keys=True,indent=2)+'\n')
        shutil.copyfile(RUNTIME/'cores.lock.json',out/'cores.lock.json')
        for filename,geo in lock['geo'].items():
            subprocess.run(['curl','-q','-fLsS','--proto','=https','--proto-redir','=https','--retry','3','--max-time','300','-o',str(out/filename),geo['url']],check=True)
            if sha(out/filename)!=geo['sha256']:raise ValueError('Geo data checksum mismatch')
        files=['V2bX','build-info.json','cores.lock.json','geoip.dat','geosite.dat']
        asset=f'V2bX-linux-{arch}.zip'
        with zipfile.ZipFile(out/asset,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
            for file in files:
                zi=zipfile.ZipInfo(file,(2026,1,1,0,0,0));zi.external_attr=(0o100755 if file=='V2bX' else 0o100644)<<16;zi.compress_type=zipfile.ZIP_DEFLATED
                z.writestr(zi,(out/file).read_bytes())
        manifest={'schema':1,'tag':lock['tag'],'version':lock['version'],'source_revision':revision,'source_state':source_state,'platform':target_os+'-'+arch,'cores':lock['modules'],'patch_index_sha256':lock['patch_index_sha256'],'geo':lock['geo'],'asset':asset,'sha256':sha(out/asset),'files':{f:sha(out/f) for f in files},'source_asset':f'source-linux-{arch}.tar.gz','source_sha256':sha(out/f'source-linux-{arch}.tar.gz')}
        (out/f'manifest-linux-{arch}.json').write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--arch',choices=['amd64','arm64'],required=True);p.add_argument('--os',default='linux');p.add_argument('--build-only',action='store_true');a=p.parse_args();build(a.output,a.arch,a.os,a.build_only)
