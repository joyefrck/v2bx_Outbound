"""Loopback-only: real HY2 -> authenticated SOCKS; sibling stays direct.

The built V2bX supplies both the standalone HY2 server and a sing-box HY2 client.
No external network, production panel, credentials or systemd is used.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import errno
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit

from runtime_xray import Direct, free_port, recv_exact

ROOT = Path(__file__).resolve().parents[1]
UUID = '00000000-0000-4000-8000-000000000001'


def main(binary):
    binary = Path(binary).resolve()
    with tempfile.TemporaryDirectory(prefix='v2bx-hy2-socks-runtime-') as tmp:
        work = Path(tmp)
        ports = []
        for _ in range(2):
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.bind(('127.0.0.1', 0))
                ports.append(s.getsockname()[1])
        local_ports = [free_port(), free_port()]
        target = ThreadingHTTPServer(('127.0.0.1', 0), Direct)
        socks = socket.socket()
        socks.bind(('127.0.0.1', 0))
        socks.listen()
        socks.settimeout(15)
        evidence, errors = [], []

        def proxy():
            try:
                conn, _ = socks.accept()
                with conn:
                    conn.settimeout(10)
                    version, count = recv_exact(conn, 2)
                    assert version == 5 and 2 in recv_exact(conn, count)
                    conn.sendall(b'\x05\x02')
                    version, count = recv_exact(conn, 2)
                    user = recv_exact(conn, count)
                    password = recv_exact(conn, recv_exact(conn, 1)[0])
                    assert (user, password) == (b'fixture', b'test:pass$`\\"')
                    conn.sendall(b'\x01\x00')
                    version, command, reserved, kind = recv_exact(conn, 4)
                    assert (version, command, reserved) == (5, 1, 0)
                    if kind == 1:
                        addr = socket.inet_ntoa(recv_exact(conn, 4))
                    elif kind == 3:
                        addr = recv_exact(conn, recv_exact(conn, 1)[0]).decode()
                    else:
                        raise AssertionError('unexpected address family')
                    port = struct.unpack('!H', recv_exact(conn, 2))[0]
                    evidence.append((addr, port))
                    conn.sendall(b'\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00')
                    request = b''
                    while b'\r\n\r\n' not in request:
                        chunk = conn.recv(1024)
                        assert chunk
                        request += chunk
                    conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nSOCKS-NODE')
            except BaseException as exc:
                errors.append(repr(exc))

        class Panel(BaseHTTPRequestHandler):
            def do_GET(self):
                request = urlsplit(self.path)
                if request.path.endswith('/config'):
                    node_id = int(parse_qs(request.query)['node_id'][0])
                    body = {'server_port': ports[node_id-201], 'server_name': 'node.invalid',
                            'obfs': '', 'up_mbps': 100, 'down_mbps': 100,
                            'base_config': {'pull_interval': 3600, 'push_interval': 3600}}
                elif request.path.endswith('/user'):
                    body = {'users': [{'id': 1, 'uuid': UUID, 'speed_limit': 0, 'device_limit': 0}]}
                else:
                    body = {'alive': {}}
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())

            def log_message(self, *_):
                pass

        panel = ThreadingHTTPServer(('127.0.0.1', 0), Panel)
        for server in (target, panel):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        proxy_thread = threading.Thread(target=proxy, daemon=True)
        proxy_thread.start()
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(work/'cert.key'), '-out', str(work/'cert.pem'), '-days', '1',
                        '-subj', '/CN=node.invalid', '-addext', 'subjectAltName=DNS:node.invalid'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        original = 'disableUDP: false\nacl:\n  inline:\n    - direct(all)\nmasquerade:\n  type: 404\n'
        (work/'hy2.yaml').write_text(original)
        client = {'inbounds': [], 'outbounds': [], 'route': {'rules': []}}
        for i, (remote, local) in enumerate(zip(ports, local_ports)):
            client['inbounds'].append({'type': 'socks', 'tag': f'client{i}',
                                      'listen': '127.0.0.1', 'listen_port': local})
            client['outbounds'].append({'type': 'hysteria2', 'tag': f'hy2{i}', 'server': '127.0.0.1',
                                       'server_port': remote, 'password': UUID, 'up_mbps': 100, 'down_mbps': 100,
                                       'tls': {'enabled': True, 'server_name': 'node.invalid',
                                               'certificate_path': str(work/'cert.pem')}})
            client['route']['rules'].append({'inbound': [f'client{i}'], 'outbound': f'hy2{i}'})
        (work/'client.json').write_text(json.dumps(client))
        config = {'Log': {'Level': 'error'}, 'Cores': [
            {'Type': 'hysteria2'}, {'Type': 'sing', 'OriginalPath': str(work/'client.json')}],
            'Nodes': [{'Core': 'hysteria2', 'NodeType': 'hysteria2', 'NodeID': n,
                       'ApiHost': f'http://127.0.0.1:{panel.server_port}', 'ApiKey': 'fixture-only',
                       'ListenIP': '127.0.0.1', 'Hysteria2ConfigPath': str(work/'hy2.yaml'),
                       'CertConfig': {'CertMode': 'file', 'CertFile': str(work/'cert.pem'),
                                      'KeyFile': str(work/'cert.key')}} for n in (201, 202)]}
        main_path = work/'config.json'
        main_path.write_text(json.dumps(config))
        endpoint = {'host': '127.0.0.1', 'port': socks.getsockname()[1], 'username': 'fixture',
                    'password': 'test:pass$`\\"', 'udp': False}
        (work/'endpoint.json').write_text(json.dumps(endpoint))
        task = work/'candidate'
        task.mkdir(mode=0o700)

        def stage(remove=False):
            subprocess.run(['bash', '-c', '''
source "$1/src/helper.sh"
TASK_DIR=$2; CONFIG_PATH=$3; WORK_DIR=${CONFIG_PATH%/*}; V2BX_BINARY=$4
if [[ $5 == remove ]]; then build_remove_candidate 0; else build_candidate 0 "$WORK_DIR/endpoint.json"; fi
''', 'runtime-hy2', str(ROOT), str(task), str(main_path), str(binary), 'remove' if remove else 'apply'], check=True)
            shutil.copyfile(task/'0.after', main_path)
            current = json.loads(main_path.read_text())
            shutil.copyfile(task/'1.after', current['Nodes'][0]['Hysteria2ConfigPath'])
            assert current['Nodes'][1] == config['Nodes'][1]
            assert (work/'hy2.yaml').read_text() == original

        def start():
            process = subprocess.Popen([str(binary), 'server', '-c', str(main_path), '--watch=false'],
                                       cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            deadline = time.monotonic()+15
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(process.stdout.read().decode()[-3000:])
                try:
                    with socket.create_connection(('127.0.0.1', local_ports[0]), 0.2):
                        pass
                    ready = True
                    for remote in ports:
                        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                            try:
                                probe.bind(('127.0.0.1', remote))
                                ready = False
                            except OSError as exc:
                                if exc.errno != errno.EADDRINUSE:
                                    raise
                    if ready:
                        return process
                    time.sleep(0.1)
                except OSError:
                    time.sleep(0.1)
            process.kill()
            process.communicate(timeout=5)
            raise RuntimeError('client listener did not start')

        def request(i):
            return subprocess.check_output(['curl', '-q', '--silent', '--show-error', '--fail', '--max-time', '10',
                '--noproxy', '', '--proxy', f'socks5h://127.0.0.1:{local_ports[i]}',
                f'http://127.0.0.1:{target.server_port}/'])

        process = None
        try:
            stage()
            process = start()
            assert request(0) == b'SOCKS-NODE'
            assert request(1) == b'DIRECT-NODE'
            proxy_thread.join(2)
            assert not errors, errors
            assert evidence == [('127.0.0.1', target.server_port)], evidence
            print('PASS: real HY2 node 201 used authenticated SOCKS; shared-config sibling 202 stayed direct.')
            process.terminate()
            process.communicate(timeout=5)
            process = None
            socks.close()
            stage(remove=True)
            process = start()
            assert request(0) == b'DIRECT-NODE'
            assert request(1) == b'DIRECT-NODE'
            print('PASS: removing HY2 SOCKS with proxy offline restored direct routing for both nodes.')
        finally:
            if process is not None:
                process.terminate()
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
            socks.close()
            for server in (target, panel):
                server.shutdown()
                server.server_close()


if __name__ == '__main__':
    main(sys.argv[1])
