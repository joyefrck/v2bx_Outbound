"""Validate generated and legacy sing config using the actual packaged runtime."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
root=Path(__file__).resolve().parents[1]
binary=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='v2bx-config-runtime-') as td:
    work=Path(td)
    subprocess.run(['bash','-c','source "$1"; check_ipv6_support(){ echo 0; }; write_route_templates "$2"','templates',str(root/'src/manager/templates.sh'),str(work)],check=True)
    origin=work/'sing_origin.json'
    modern=json.loads(origin.read_text())
    for mode in ['modern','legacy']:
        if mode=='legacy':
            modern['dns']['servers']=[{'tag':'cf','address':'1.1.1.1'}]
            modern['outbounds'].append({'type':'block','tag':'block'})
            for rule in modern['route']['rules']:
                if rule.get('action')=='reject':del rule['action'];rule['outbound']='block'
            origin.write_text(json.dumps(modern))
        main=work/'config.json';main.write_text(json.dumps({'Cores':[{'Type':'sing','OriginalPath':str(origin)}],'Nodes':[]}))
        digest=hashlib.sha256(origin.read_bytes()).digest()
        subprocess.run([str(binary),'check-config','-c',str(main)],cwd=work,check=True)
        with (work/'server.log').open('w') as log:
            proc=subprocess.Popen([str(binary),'server','-c',str(main)],cwd=work,stdout=log,stderr=log)
            try:
                time.sleep(1)
                if proc.poll() is not None:raise RuntimeError((work/'server.log').read_text())
            finally:
                proc.terminate();proc.wait(timeout=10)
        assert hashlib.sha256(origin.read_bytes()).digest()==digest,'original config was modified'
    main.write_text(json.dumps({'Cores':[{'Type':'xray','AssetPath':str(binary.parent),'RouteConfigPath':str(work/'route.json'),'OutboundConfigPath':str(work/'custom_outbound.json')}],'Nodes':[]}))
    subprocess.run([str(binary),'check-config','-c',str(main)],cwd=work,check=True)
print('PASS: modern/legacy sing-box configs start without rewriting files; generated Xray routes pass preflight with packaged Geo data.')
