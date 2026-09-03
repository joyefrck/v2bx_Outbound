"""Optional local integration test: run with a V2bX v0.4.0 binary path.

Only loopback listeners, disposable fixture accounts and temporary configs are used.
No panel API or real residential proxy is contacted.
"""
import json
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

root = Path(__file__).resolve().parents[1]


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False).encode()


def recv_exact(sock, count):
    result = b""
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise RuntimeError("unexpected EOF")
        result += chunk
    return result


def node_tag(node):
    return f'[{node["ApiHost"]}]-{node["NodeType"].lower()}:{node["NodeID"]}'


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Direct(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"DIRECT-NODE")

    def log_message(self, *args):
        pass


def main(binary):
    with tempfile.TemporaryDirectory(prefix="v2bx-xray-runtime-") as directory:
        directory = Path(directory)
        socks = socket.socket()
        socks.bind(("127.0.0.1", 0))
        socks.listen()
        socks.settimeout(10)
        target = HTTPServer(("127.0.0.1", 0), Direct)
        target_thread = threading.Thread(target=target.serve_forever, daemon=True)
        target_thread.start()
        evidence, errors = [], []

        def proxy():
            try:
                conn, _ = socks.accept()
                with conn:
                    conn.settimeout(10)
                    version, count = recv_exact(conn, 2)
                    methods = recv_exact(conn, count)
                    assert version == 5 and 2 in methods
                    conn.sendall(b"\x05\x02")
                    version, count = recv_exact(conn, 2)
                    user = recv_exact(conn, count)
                    password = recv_exact(conn, recv_exact(conn, 1)[0])
                    assert (user, password) == (b"fixture", b"test:pass$`\\\"")
                    conn.sendall(b"\x01\x00")
                    version, command, reserved, kind = recv_exact(conn, 4)
                    assert (version, command, reserved) == (5, 1, 0)
                    if kind == 1:
                        address = socket.inet_ntoa(recv_exact(conn, 4))
                    elif kind == 3:
                        address = recv_exact(conn, recv_exact(conn, 1)[0]).decode()
                    else:
                        raise AssertionError("unexpected address family")
                    port = struct.unpack("!H", recv_exact(conn, 2))[0]
                    evidence.append((address, port))
                    conn.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
                    request = bytearray()
                    while b"\r\n\r\n" not in request:
                        chunk = conn.recv(1024)
                        assert chunk, "HTTP request closed early"
                        request.extend(chunk)
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nSOCKS-NODE")
            except BaseException as exc:
                errors.append(type(exc).__name__)

        proxy_thread = threading.Thread(target=proxy, daemon=True)
        proxy_thread.start()
        node = {"Core": "xray", "ApiHost": "https://panel.invalid", "NodeType": "vless", "NodeID": 11}
        nodes = [node, dict(node, NodeID=12)]
        core = {"Type": "xray", "AssetPath": str(directory), "Log": {"Level": "error"},
                "OutboundConfigPath": str(directory / "out.json"),
                "RouteConfigPath": str(directory / "route.json"),
                "InboundConfigPath": str(directory / "in.json")}
        config = {"Log": {"Level": "error"}, "Cores": [core], "Nodes": nodes}
        (directory / "config.json").write_bytes(json_bytes(config))
        (directory / "out.json").write_bytes(json_bytes([
            {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}]))
        (directory / "route.json").write_bytes(json_bytes({"rules": [
            {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}]}))
        endpoint = {"host": "127.0.0.1", "port": socks.getsockname()[1], "username": "fixture",
                    "password": 'test:pass$`\\"', "udp": False}
        (directory / "endpoint.json").write_bytes(json_bytes(endpoint))
        task = directory / "work"
        task.mkdir(mode=0o700)
        subprocess.run(["bash", "-c", '''
source "$1"
TASK_DIR=$2
CONFIG_PATH=$3
WORK_DIR=${CONFIG_PATH%/*}
build_candidate 0 "$4"
''', "runtime-test", str(root / "src/helper.sh"), str(task), str(directory / "config.json"),
                        str(directory / "endpoint.json")], check=True)
        shutil.copyfile(task / "0.after", directory / "out.json")
        shutil.copyfile(task / "1.after", directory / "route.json")
        ports = [free_port(), free_port()]
        (directory / "in.json").write_bytes(json_bytes([
            {"tag": node_tag(node), "listen": "127.0.0.1", "port": port, "protocol": "socks",
             "settings": {"auth": "noauth", "udp": False}}
            for node, port in zip(nodes, ports)]))
        # Static loopback inbounds reproduce V2bX's generated node tags; no panel is called.
        config["Nodes"] = []
        (directory / "config.json").write_bytes(json_bytes(config))
        process = subprocess.Popen([str(Path(binary).resolve()), "server", "-c", str(directory / "config.json"), "--watch=false"],
                                   cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 15
            while True:
                if process.poll() is not None:
                    raise RuntimeError("V2bX failed: " + process.stdout.read().decode()[-3000:])
                try:
                    with socket.create_connection(("127.0.0.1", ports[0]), 0.2):
                        break
                except OSError:
                    if time.monotonic() > deadline:
                        raise RuntimeError("V2bX did not start")
                    time.sleep(0.1)
            responses = []
            for port in ports:
                responses.append(subprocess.check_output([
                    "curl", "-q", "--silent", "--show-error", "--fail", "--max-time", "10",
                    "--noproxy", "", "--proxy", f"socks5h://127.0.0.1:{port}",
                    f"http://127.0.0.1:{target.server_port}/"]))
            proxy_thread.join(2)
            assert not errors, errors
            assert b"SOCKS-NODE" in responses[0], responses[0]
            assert b"DIRECT-NODE" in responses[1], responses[1]
            assert len(evidence) == 1, evidence
            print("PASS: V2bX v0.4.0 accepted generated Xray config; node 11 used authenticated SOCKS; node 12 stayed direct.")
        finally:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
            socks.close()
            target.shutdown()
            target.server_close()


if __name__ == "__main__":
    main(sys.argv[1])
