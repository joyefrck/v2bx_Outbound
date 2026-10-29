"""Start generated HY2 with installed Geo assets and unrelated working-directory files.

Uses a loopback panel, a temporary self-signed certificate and a local rejecting
HTTP proxy. No production credentials or external panel/downloads are needed.
"""
import errno
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
binary = Path(sys.argv[1]).resolve()
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reserve:
    reserve.bind(('127.0.0.1', 0))
    port = reserve.getsockname()[1]
panel_paths = []
downloads = []


class Panel(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        panel_paths.append(path)
        if path.endswith('/config'):
            body = {'server_port': port, 'server_name': 'node.invalid', 'obfs': '',
                    'up_mbps': 100, 'down_mbps': 100,
                    'base_config': {'push_interval': 3600, 'pull_interval': 3600}}
        elif path.endswith('/user'):
            body = {'users': [{'id': 1, 'uuid': '00000000-0000-4000-8000-000000000001',
                               'speed_limit': 0, 'device_limit': 0}]}
        else:
            body = {'alive': {}}
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def log_message(self, *_):
        pass


class RejectDownloads(BaseHTTPRequestHandler):
    def do_CONNECT(self):
        downloads.append(self.path)
        self.send_error(502, 'external access disabled in test')

    def do_GET(self):
        downloads.append(self.path)
        self.send_error(502, 'external access disabled in test')

    def log_message(self, *_):
        pass


panel = ThreadingHTTPServer(('127.0.0.1', 0), Panel)
proxy = ThreadingHTTPServer(('127.0.0.1', 0), RejectDownloads)
for server in [panel, proxy]:
    threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='v2bx-hy2-geo-runtime-') as td:
        work = Path(td)
        installed, stage, cwd = (work / name for name in ['installed', 'candidate', 'cwd'])
        for directory in [installed, stage, cwd]:
            directory.mkdir()
        for name in ['geoip.dat', 'geosite.dat']:
            shutil.copyfile(binary.parent / name, installed / name)
            # Explicit paths must use even old installed files without downloading.
            os.utime(installed / name, (1, 1))
            (cwd / name).write_bytes(b'unrelated-invalid-working-directory-database')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(installed / 'cert.key'), '-out', str(installed / 'fullchain.cer'),
                        '-days', '1', '-subj', '/CN=node.invalid'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        answers = (f'http://127.0.0.1:{panel.server_port}\nfixture-key\ny\n3\n1\n3\nnode.invalid\n'
                   f'{installed / "fullchain.cer"}\n{installed / "cert.key"}\nn\n')
        generated = subprocess.run(['bash', '-c', '''
source "$1/v2bx-manager.sh"
M_CONFIG=$2
m_ask() { IFS= read -r M_REPLY; }
m_secret() { IFS= read -r M_REPLY; }
check_ipv6_support() { printf 0; }
m_build_config "$3"
''', 'hy2-geo-runtime', str(ROOT), str(installed), str(stage)],
                                   input=answers, capture_output=True, text=True)
        assert generated.returncode == 0, generated.stdout + generated.stderr
        for source in stage.iterdir():
            shutil.copyfile(source, installed / source.name)
        shutil.rmtree(stage)
        main = installed / 'config.json'
        config = json.loads(main.read_text())
        config['Nodes'][0]['ListenIP'] = '127.0.0.1'
        main.write_text(json.dumps(config))
        originals = {p: hashlib.sha256(p.read_bytes()).digest()
                     for directory in [installed, cwd] for p in directory.iterdir()}
        env = dict(os.environ, HTTP_PROXY=f'http://127.0.0.1:{proxy.server_port}',
                   HTTPS_PROXY=f'http://127.0.0.1:{proxy.server_port}', NO_PROXY='127.0.0.1,localhost')
        subprocess.run([str(binary), 'check-config', '-c', str(main)], cwd=cwd, env=env, check=True)
        with (work / 'runtime.log').open('w') as log:
            proc = subprocess.Popen([str(binary), 'server', '-c', str(main), '--watch=false'],
                                    cwd=cwd, env=env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                listening = False
                while time.monotonic() < deadline and proc.poll() is None:
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                        try:
                            probe.bind(('127.0.0.1', port))
                        except OSError as error:
                            if error.errno != errno.EADDRINUSE:
                                raise
                            listening = True
                    if listening and any(p.endswith('/user') for p in panel_paths):
                        break
                    time.sleep(.1)
                assert listening and proc.poll() is None, (work / 'runtime.log').read_text()
                assert any(p.endswith('/config') for p in panel_paths), panel_paths
                assert any(p.endswith('/user') for p in panel_paths), panel_paths
                assert not downloads, downloads
                assert all(hashlib.sha256(p.read_bytes()).digest() == h for p, h in originals.items())
            finally:
                if proc.poll() is None:
                    proc.terminate()
                proc.wait(timeout=10)
finally:
    panel.shutdown()
    proxy.shutdown()
print('PASS: generated HY2 starts after stage removal, uses installed Geo assets from another cwd, and makes no downloads.')
