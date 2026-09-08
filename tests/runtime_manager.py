"""Opt-in: ONLY run in a disposable root/systemd Linux VM or test container.

Requires an installed V2bX v0.4.0 binary and integrated tools. Creates real nodes
against a loopback panel fixture, checks direct -> authenticated SOCKS forwarding,
and stops the service on exit. No production credentials or panel is used.
"""
import json
import os
from pathlib import Path
import pty
import select
import socket
import struct
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
USER = '11111111-1111-4111-8111-111111111111'
KEY = 'fixture-"key\\only'
DEST = '93.184.216.34'  # Assigned to loopback exclusively inside the disposable container.


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def exact(s, count):
    data = b''
    while len(data) < count:
        chunk = s.recv(count-len(data))
        assert chunk, 'unexpected EOF'
        data += chunk
    return data


def main():
    assert os.environ.get('V2BX_MANAGER_RUNTIME_TEST') == '1', 'requires explicit disposable-environment opt-in'
    assert not Path('/etc/V2bX/config.json').exists(), 'requires a fresh installation with no node config'
    ports = [free_port(), free_port()]
    requests = []

    class Panel(BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urlparse(self.path)
            q = parse_qs(parsed.query)
            assert q.get('token') == [KEY]
            nid = int(q['node_id'][0])
            requests.append((parsed.path, nid))
            if parsed.path.endswith('/config'):
                body = {'server_port': ports[0 if nid in (1, 3) else 1], 'tls': 0, 'network': 'tcp', 'network_settings': {},
                        'flow': '', 'base_config': {'push_interval': 60, 'pull_interval': 60}, 'routes': []}
            elif parsed.path.endswith('/user'):
                body = {'users': [{'id': 1, 'uuid': USER, 'speed_limit': 0, 'device_limit': 0}]}
            else:
                body = {'alive': {}}
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(body).encode())

        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{}')

        def log_message(self, *_):
            pass

    panel = ThreadingHTTPServer(('127.0.0.1', 0), Panel)
    threading.Thread(target=panel.serve_forever, daemon=True).start()
    pid, fd = pty.fork()
    if pid == 0:
        os.execv('/usr/bin/v2bx', ['v2bx', 'generate'])
    output = bytearray()
    cursor = 0

    def answer(prompt, value, timeout=45):
        nonlocal cursor
        marker = prompt.encode()
        deadline = time.monotonic()+timeout
        while marker not in output[cursor:]:
            assert time.monotonic() < deadline, f'timeout at {prompt}'
            if select.select([fd], [], [], .2)[0]:
                output.extend(os.read(fd, 65536))
        cursor = output.index(marker, cursor)+len(marker)
        os.write(fd, value.encode()+b'\n')

    try:
        answer('继续生成配置？', 'y')
        answer('请输入面板网址', f'http://127.0.0.1:{panel.server_port}')
        answer('请输入面板对接 API Key', KEY)
        answer('后续节点是否共用', 'y')
        for nid in (1, 2):
            answer('节点核心：', '1')
            answer('请输入节点 Node ID', str(nid))
            answer('协议：', '2')
            answer('是否为 Reality', 'n')
            answer('是否配置 TLS', 'n')
            answer('是否继续添加节点', 'y' if nid == 1 else 'n')
        answer('确认保存配置并重启', 'y')
        answer('是否配置 SOCKS 出口？', 'n', 60)
        deadline = time.monotonic()+10
        while time.monotonic() < deadline:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                assert os.waitstatus_to_exitcode(status) == 0
                break
            if select.select([fd], [], [], .1)[0]:
                try:
                    output.extend(os.read(fd, 65536))
                except OSError:
                    pass
        else:
            raise AssertionError('wizard did not exit')
        assert KEY.encode() not in output, 'API key echoed in terminal'
        assert json.loads(Path('/etc/V2bX/config.json').read_text())['Nodes'][0]['ApiKey'] == KEY
        assert all(('/api/v1/server/UniProxy/user', i) in requests for i in (1, 2))
        print('PASS: actual TTY wizard generated two nodes; hidden API key round-tripped; real systemd service stable; SOCKS skipped.')

        subprocess.run(['ip', 'addr', 'replace', DEST+'/32', 'dev', 'lo'], check=True)

        class Destination(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'DIRECT-EXIT')

            def log_message(self, *_):
                pass

        target = ThreadingHTTPServer((DEST, 0), Destination)
        threading.Thread(target=target.serve_forever, daemon=True).start()

        def vless(port):
            with socket.create_connection(('127.0.0.1', port), 5) as s:
                s.settimeout(10)
                s.sendall(b'\0'+uuid.UUID(USER).bytes+b'\0\1'+struct.pack('!H', target.server_port)+b'\1'+socket.inet_aton(DEST)+
                          f'GET / HTTP/1.1\r\nHost: {DEST}\r\nConnection: close\r\n\r\n'.encode())
                data = b''
                while True:
                    part = s.recv(65536)
                    if not part:
                        return data
                    data += part

        assert all(b'DIRECT-EXIT' in vless(port) for port in ports)
        proxy = socket.socket()
        proxy.bind(('127.0.0.1', 0))
        proxy.listen()
        evidence = []

        def socks_server():
            while True:
                conn, _ = proxy.accept()
                with conn:
                    version, count = exact(conn, 2)
                    assert version == 5 and 2 in exact(conn, count)
                    conn.sendall(b'\5\2')
                    version, count = exact(conn, 2)
                    user = exact(conn, count)
                    password = exact(conn, exact(conn, 1)[0])
                    assert (user, password) == (b'fixture', b'fixture-password')
                    conn.sendall(b'\1\0')
                    assert exact(conn, 4) == b'\5\1\0\1'
                    assert socket.inet_ntoa(exact(conn, 4)) == DEST
                    assert struct.unpack('!H', exact(conn, 2))[0] == target.server_port
                    evidence.append(True)
                    conn.sendall(b'\5\0\0\1'+b'\0'*6)
                    conn.recv(65536)
                    conn.sendall(b'HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nSOCKS-EXIT')

        threading.Thread(target=socks_server, daemon=True).start()
        endpoint = Path('/tmp/manager-runtime-endpoint.json')
        endpoint.write_text(json.dumps({'host': '127.0.0.1', 'port': proxy.getsockname()[1],
                                        'username': 'fixture', 'password': 'fixture-password', 'udp': False}))
        endpoint.chmod(0o600)
        subprocess.run(['bash', '-c', '''
source /usr/local/bin/v2bx-socks
umask 077
SELF_PATH=/usr/local/bin/v2bx-socks
TASK_DIR=$(mktemp -d /tmp/v2bx-socks.runtime.XXXXXX)
trap cleanup EXIT
discover && healthy 0 || exit 1
exec 8>"${CONFIG_PATH%/*}/.v2bx-socks.lock"; flock -n 8 || exit 1
build_candidate 0 "$1" && submit_job apply || exit 1
wait_job
[[ $(jq -r .status "$JOB_DIR/result.json") == succeeded ]]
''', 'runtime-apply', str(endpoint)], check=True, timeout=60)
        endpoint.unlink()
        assert b'SOCKS-EXIT' in vless(ports[0])
        assert b'DIRECT-EXIT' in vless(ports[1])
        assert evidence
        print('PASS: real VLESS client traffic was direct before apply; node 1 then used authenticated SOCKS, node 2 remained direct.')
        def manage(steps):
            child, terminal = pty.fork()
            if child == 0:
                os.execv('/usr/bin/v2bx', ['v2bx', 'config'])
            captured = bytearray()
            offset = 0
            try:
                for prompt, value in steps:
                    marker = prompt.encode()
                    deadline = time.monotonic()+45
                    while marker not in captured[offset:]:
                        assert time.monotonic() < deadline, f'node manager timeout at {prompt}'
                        if select.select([terminal], [], [], .2)[0]:
                            captured.extend(os.read(terminal, 65536))
                    offset = captured.index(marker, offset)+len(marker)
                    os.write(terminal, value.encode()+b'\n')
                deadline = time.monotonic()+50
                while time.monotonic() < deadline:
                    done, status = os.waitpid(child, os.WNOHANG)
                    if done:
                        assert os.waitstatus_to_exitcode(status) == 0, captured.decode(errors='replace')
                        assert KEY.encode() not in captured, 'API key echoed'
                        return
                    if select.select([terminal], [], [], .1)[0]:
                        try:
                            captured.extend(os.read(terminal, 65536))
                        except OSError:
                            pass
                raise AssertionError('node manager did not exit')
            finally:
                os.close(terminal)

        manage([('请选择操作', '1'), ('请选择要处理的节点序号', '1'), ('确认处理这个节点', 'y'),
                ('请选择修改项', '3'), ('节点 ID（回车保留）', '3'), ('请选择修改项', '0'),
                ('确认备份并应用', 'y')])
        assert json.loads(Path('/etc/V2bX/config.json').read_text())['Nodes'][0]['NodeID'] == 3
        assert b'SOCKS-EXIT' in vless(ports[0])
        assert b'DIRECT-EXIT' in vless(ports[1])
        print('PASS: guided Node ID edit preserved the actual SOCKS route and the other node.')

        manage([('请选择操作', '3'), ('请选择要处理的节点序号', '2'), ('确认处理这个节点', 'y'),
                ('确认备份并应用', 'y')])
        assert len(json.loads(Path('/etc/V2bX/config.json').read_text())['Nodes']) == 1
        assert b'SOCKS-EXIT' in vless(ports[0])
        manage([('请选择操作', '2'), ('请选择内核序号', '1'),
                ('请输入面板网址', f'http://127.0.0.1:{panel.server_port}'), ('请输入面板对接 API Key', KEY),
                ('请输入节点 Node ID', '2'), ('协议：', '2'), ('是否为 Reality', 'n'), ('是否配置 TLS', 'n'),
                ('确认备份并应用', 'y')])
        assert b'SOCKS-EXIT' in vless(ports[0])
        assert b'DIRECT-EXIT' in vless(ports[1])
        print('PASS: guided delete/add selected the correct nodes and preserved the remaining SOCKS exit.')

        manage([('请选择操作', '3'), ('请选择要处理的节点序号', '1'), ('确认处理这个节点', 'y'),
                ('确认备份并应用', 'y')])
        assert 'v2bx-socks-' not in Path('/etc/V2bX/custom_outbound.json').read_text()
        assert 'v2bx-socks-' not in Path('/etc/V2bX/route.json').read_text()
        assert b'DIRECT-EXIT' in vless(ports[1])
        manage([('请选择操作', '3'), ('请选择要处理的节点序号', '1'), ('确认处理这个节点', 'y'),
                ('确认备份并应用', 'y')])
        assert json.loads(Path('/etc/V2bX/config.json').read_text())['Nodes'] == []
        assert subprocess.run(['systemctl', 'is-active', '--quiet', 'V2bX']).returncode != 0
        print('PASS: deleting the SOCKS node cleaned its managed rules; deleting the final node stopped the service.')
        target.shutdown()
        proxy.close()
    finally:
        os.close(fd)
        subprocess.run(['systemctl', 'stop', 'V2bX'], check=False)
        panel.shutdown()


if __name__ == '__main__':
    main()
