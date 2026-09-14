"""Archive corresponding source, licences and build instructions, without secrets."""
import json
import gzip
from pathlib import Path
import subprocess
import tarfile

def archive(source, modfile, tags, env, target, root):
    lines=subprocess.check_output(['go','list','-mod=readonly','-modfile='+str(modfile),'-tags',' '.join(tags),'-deps','-f','{{if .Module}}{{.Module.Path}}\t{{.Module.Version}}\t{{.Module.Dir}}{{end}}','.'],cwd=source,env=env,text=True).splitlines()
    modules={}
    for line in lines:
        if not line.strip():continue
        path,version,directory=line.split('\t')
        if Path(directory)==source:continue
        modules[path]={'version':version,'directory':directory,'archive':'modules/'+path+'@'+version}
    def normalized(info):
        if '__pycache__' in info.name:return None
        info.uid=info.gid=0;info.uname=info.gname='';info.mtime=0;info.pax_headers={}
        info.mode=0o755 if info.isdir() or info.mode & 0o111 else 0o644
        return info
    with open(target,'wb') as raw, gzip.GzipFile(filename='',mode='wb',fileobj=raw,mtime=0,compresslevel=3) as compressed, tarfile.open(fileobj=compressed,mode='w') as tar:
        for path in sorted(source.iterdir()):
            if path.name=='patched.deps':continue
            tar.add(path,arcname='runtime/'+path.name,filter=normalized)
        for module in modules.values():tar.add(module['directory'],arcname=module['archive'],filter=normalized)
        tar.add(root/'scripts',arcname='scripts',filter=normalized)
        readme=source/'SOURCE-README.txt'
        readme.write_text('Corresponding source for this integrated V2bX build. Original and modified module licences are included in each module directory.\n'
          'Use Go 1.26.1 with GOEXPERIMENT=jsonv2. For an offline source rebuild, edit runtime/patched.mod to replace each path in modules.json with ../modules/<path>@<version>, then run go build -modfile=patched.mod -mod=readonly -tags "'+ ' '.join(tags)+'" . from runtime/.\n'
          'Some sources include example/test keys from public upstream fixtures. None are deployment credentials.\n')
        tar.add(readme,arcname='SOURCE-README.txt',filter=normalized)
        mp=source/'modules.json';mp.write_text(json.dumps({k:{'version':v['version'],'archive':v['archive']} for k,v in modules.items()},sort_keys=True,indent=2))
        tar.add(mp,arcname='modules.json',filter=normalized)
