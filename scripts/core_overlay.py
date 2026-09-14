#!/usr/bin/env python3
"""Verify patch bases against checksum-verified Go modules and prepare private patched module copies."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import shutil

ROOT = Path(__file__).resolve().parents[1]

def generate(output):
    patches = ROOT / 'runtime/patches'
    index = json.loads((patches / 'index.json').read_text())
    modules = {}
    replace = {}
    for item in index:
        module = item['module']
        if module not in modules:
            info = json.loads(subprocess.check_output(['go','mod','download','-json', module], cwd=ROOT/'runtime', text=True))
            if info.get('Error') or not info.get('Sum'): raise ValueError('unverified module: '+module)
            modules[module] = Path(info['Dir'])
        original = modules[module] / item['path']
        if original.exists():
            actual = hashlib.sha256(original.read_bytes()).hexdigest()
        else: actual = None
        if actual != item['upstream_sha256']: raise ValueError('patch base mismatch: '+str(original))
        replacement = patches / item['replacement']
        if not replacement.is_file(): raise ValueError('missing patch: '+str(replacement))
        replace[str(original)] = str(replacement)
    # Go deliberately forbids overlays inside GOMODCACHE. Patch private copies,
    # leaving the shared checksum-verified cache intact.
    stage = Path(output).resolve().with_suffix('.deps')
    stage.mkdir(exist_ok=True)
    modfile = Path(output).resolve().with_suffix('.mod')
    shutil.copyfile(ROOT/'runtime/go.mod', modfile)
    shutil.copyfile(ROOT/'runtime/go.sum', modfile.with_suffix('.sum'))
    for module, source in modules.items():
        dest = stage / module.replace('/', '_')
        if dest.exists(): shutil.rmtree(dest)
        shutil.copytree(source, dest)
        dest.chmod(0o755)
        for directory in dest.rglob("*"):
            if directory.is_dir(): directory.chmod(0o755)
        for original, replacement in replace.items():
            try: relative = Path(original).relative_to(source)
            except ValueError: continue
            target = dest / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.chmod(0o644) if target.exists() else None
            shutil.copyfile(replacement, target)
        subprocess.run(['go','mod','edit','-modfile='+str(modfile),'-replace='+module.split('@')[0]+'='+str(dest)],cwd=ROOT/'runtime',check=True)
    Path(output).write_text(json.dumps({'Replace':{}}, indent=2)+'\n')
    return modfile

if __name__ == '__main__':
    p=argparse.ArgumentParser(); p.add_argument('output'); args=p.parse_args(); print(generate(args.output))
