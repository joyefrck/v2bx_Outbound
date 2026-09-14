#!/usr/bin/env python3
"""Read-only discovery: emit candidates; never change locks or publish binaries."""
import json
import os
from pathlib import Path
import urllib.request

lock=json.loads((Path(__file__).resolve().parents[1]/'runtime/cores.lock.json').read_text())
results=[]
for name,current in lock['modules'].items():
    if name.endswith('-extras'):continue
    req=urllib.request.Request('https://api.github.com/repos/'+current['repository']+'/releases/latest',headers={'Accept':'application/vnd.github+json','User-Agent':'v2bx-upstream-check'})
    if os.environ.get('GH_TOKEN'):req.add_header('Authorization','Bearer '+os.environ['GH_TOKEN'])
    with urllib.request.urlopen(req,timeout=30) as response:release=json.load(response)
    if release['draft'] or release['prerelease']:raise ValueError('latest response is not stable')
    results.append({'core':name,'locked':current['tag'],'upstream':release['tag_name'],'candidate':current['tag']!=release['tag_name'],'url':release['html_url']})
print(json.dumps(results,ensure_ascii=False,indent=2))
if os.environ.get('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as summary:
        summary.write('Official upstream discovery (candidates only; no automatic promotion)\n\n')
        for result in results:summary.write(f'- {result["core"]}: {result["locked"]} → {result["upstream"]}; candidate={result["candidate"]}\n')
