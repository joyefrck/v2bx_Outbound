import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def build(output, target_os=None, arch=None):
    lock = json.loads((ROOT/'tests/mihomo-client.lock.json').read_text())
    toolchain = json.loads((ROOT/'runtime/cores.lock.json').read_text())['go']
    environment = dict(os.environ, GOTOOLCHAIN=toolchain, CGO_ENABLED='0')
    if target_os:
        environment['GOOS'] = target_os
    if arch:
        environment['GOARCH'] = arch
    metadata = json.loads(subprocess.check_output(['go', 'mod', 'download', '-json', lock['module']+'@'+lock['version']], cwd=ROOT, env=environment, text=True))
    if metadata.get('Sum') != lock['sum'] or metadata.get('GoModSum') != lock['go_mod_sum'] or metadata.get('Origin', {}).get('Hash') != lock['commit']:
        raise ValueError('test client source differs from the reviewed lock')
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    version = lock['version'].removeprefix('v')
    subprocess.run(['go', 'build', '-mod=readonly', '-trimpath', '-ldflags', '-X github.com/metacubex/mihomo/constant.Version='+version, '-o', str(output), '.'], cwd=metadata['Dir'], env=environment, check=True)
    print('Built verified test-only Mihomo '+lock['version'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--os')
    parser.add_argument('--arch')
    args = parser.parse_args()
    build(args.output, args.os, args.arch)
