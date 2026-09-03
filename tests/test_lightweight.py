"""Development tests only; Python is not used by the delivered shell script."""
import json
import os
from pathlib import Path
import pty
import select
import shlex
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "src/helper.sh"
ENDPOINT = {"host": "127.0.0.1", "port": 1080, "username": "test:user", "password": 'p:a$`"\\ss', "udp": False}


def exact(sock, n):
    result = b""
    while len(result) < n:
        chunk = sock.recv(n - len(result))
        if not chunk:
            raise RuntimeError("closed")
        result += chunk
    return result


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="v2bx-socks.tests.")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.task = self.root / "work"
        self.task.mkdir(mode=0o700)
        self.config = self.root / "config.json"
        self.out = self.root / "out.json"
        self.route = self.root / "route.json"
        self.origin = self.root / "sing.json"
        self.endpoint = self.root / "endpoint.json"
        self.write(self.endpoint, ENDPOINT)

    def write(self, path, data):
        path.write_text(json.dumps(data, ensure_ascii=False))
        path.chmod(0o600)

    def setup_config(self, kind="xray", fallback=True, two_nodes=False):
        core = {"Type": kind}
        if kind == "xray":
            core.update(OutboundConfigPath=str(self.out), RouteConfigPath=str(self.route))
            self.write(self.out, [{"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}])
            rules = [{"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}]
            if fallback:
                rules.append({"type": "field", "network": "udp,tcp", "outboundTag": "direct"})
            self.write(self.route, {"domainStrategy": "AsIs", "rules": rules})
        else:
            core["OriginalPath"] = str(self.origin)
            rules = [{"ip_is_private": True, "outbound": "block"}]
            if fallback:
                rules.append({"network": ["tcp", "udp"], "outbound": "direct"})
            self.write(self.origin, {"dns": {"servers": [{"tag": "cf", "address": "1.1.1.1"}]},
                                    "outbounds": [{"tag": "direct", "type": "direct"}, {"tag": "block", "type": "block"}],
                                    "route": {"rules": rules}})
        nodes = [{"Core": kind, "NodeType": "vless", "NodeID": 11, "ApiHost": "https://panel.invalid",
                  "ApiKey": "fixture-only"}]
        if two_nodes:
            nodes.append(dict(nodes[0], NodeID=12))
        self.write(self.config, {"Cores": [core], "Nodes": nodes})

    def shell(self, code, check=True, timeout=20):
        prefix = '\n'.join([
            'source "$1"', 'TASK_DIR=$2', 'CONFIG_PATH=$3', 'WORK_DIR=${CONFIG_PATH%/*}',
            'BACKUP_ROOT=$WORK_DIR/backups', 'umask 077',
        ])
        p = subprocess.run(["bash", "-c", prefix + "\n" + code, "test", str(SCRIPT), str(self.task),
                            str(self.config), str(self.endpoint)], capture_output=True, text=True, timeout=timeout)
        if check and p.returncode:
            self.fail(p.stdout + "\n" + p.stderr)
        return p

    def build(self, index=0, check=True):
        return self.shell('build_candidate %d "$4"' % index, check)

    def generated(self):
        return json.loads((self.task / "generated.json").read_text())

    def install_candidate(self, kind="xray"):
        if kind == "xray":
            self.out.write_bytes((self.task / "0.after").read_bytes())
            self.route.write_bytes((self.task / "1.after").read_bytes())
        else:
            self.origin.write_bytes((self.task / "0.after").read_bytes())


class RoutingTests(Fixture):
    def test_xray_node_scope_keeps_other_node_and_blocks(self):
        self.setup_config(two_nodes=True)
        before = self.config.read_bytes()
        self.build()
        result = self.generated()
        rules = result["route"]["rules"]
        self.assertEqual(rules[0]["outboundTag"], "block")
        self.assertEqual(rules[-1]["outboundTag"], "direct")
        self.assertEqual(rules[-2]["inboundTag"], ["[https://panel.invalid]-vless:11"])
        self.assertEqual(rules[1]["network"], "udp")
        account = next(x for x in result["out"] if x["protocol"] == "socks")["settings"]["servers"][0]["users"][0]
        self.assertEqual(account, {"user": ENDPOINT["username"], "pass": ENDPOINT["password"]})
        self.assertEqual(before, self.config.read_bytes())

    def test_xray_without_catchall_matches_current_server(self):
        self.setup_config(fallback=False)
        self.build()
        self.assertEqual(len(self.generated()["route"]["rules"]), 3)

    def test_sing_reconfiguration_remains_before_direct(self):
        self.setup_config("sing")
        self.build()
        first = self.generated()
        self.install_candidate("sing")
        self.build()
        self.assertEqual(first["origin"], self.generated()["origin"])
        self.write(self.endpoint, dict(ENDPOINT, udp=True))
        self.build()
        rules = self.generated()["origin"]["route"]["rules"]
        self.assertEqual(rules[-1]["outbound"], "direct")
        self.assertTrue(rules[-2]["outbound"].startswith("v2bx-socks-"))
        self.assertFalse(any(r.get("action") == "reject" for r in rules))

    def test_xray_reconfiguration_no_duplicates_and_udp_toggle(self):
        self.setup_config()
        self.build()
        first = self.generated()
        self.install_candidate()
        self.build()
        self.assertEqual(first, self.generated())
        self.write(self.endpoint, dict(ENDPOINT, udp=True))
        self.build()
        self.assertEqual(len(self.generated()["route"]["rules"]), 3)

    def test_different_nodes_can_have_separate_exits(self):
        self.setup_config(two_nodes=True)
        self.build()
        self.install_candidate()
        self.write(self.endpoint, dict(ENDPOINT, port=1090))
        self.build(index=1)
        ports = [o["settings"]["servers"][0]["port"] for o in self.generated()["out"] if o["protocol"] == "socks"]
        self.assertEqual(ports, [1080, 1090])

    def test_sing_domain_reuses_dns(self):
        self.setup_config("sing")
        self.write(self.endpoint, dict(ENDPOINT, host="socks.example.com"))
        self.build()
        self.assertEqual(self.generated()["out"][-1]["domain_resolver"]["server"], "cf")

    def test_custom_rules_refused_without_writes(self):
        self.setup_config()
        route = json.loads(self.route.read_text())
        route["rules"].insert(1, {"type": "field", "domain": ["example.com"], "outboundTag": "direct"})
        self.write(self.route, route)
        before = self.route.read_bytes()
        self.assertNotEqual(self.build(check=False).returncode, 0)
        self.assertEqual(before, self.route.read_bytes())

    def test_shared_core_file_refused(self):
        self.setup_config()
        config = json.loads(self.config.read_text())
        config["Cores"].append(dict(config["Cores"][0], Name="second"))
        self.write(self.config, config)
        self.assertNotEqual(self.build(check=False).returncode, 0)

    def test_symlink_refused(self):
        self.setup_config()
        other = self.root / "other.json"
        self.route.rename(other)
        self.route.symlink_to(other)
        self.assertNotEqual(self.build(check=False).returncode, 0)

    def test_empty_name_uses_default_tags(self):
        self.setup_config()
        config = json.loads(self.config.read_text())
        config["Nodes"][0]["Name"] = ""
        config["Cores"][0]["Name"] = ""
        self.write(self.config, config)
        self.build()
        self.assertEqual(self.generated()["route"]["rules"][-2]["inboundTag"], ["[https://panel.invalid]-vless:11"])

    def test_validation_rejects_invalid_endpoint(self):
        for change in ({"host": "socks://host:1080"}, {"port": 0}, {"port": 70000}, {"password": "x\ny"}, {"password": "x"*256}):
            self.write(self.endpoint, dict(ENDPOINT, **change))
            self.assertNotEqual(self.shell('validate_endpoint "$4"', check=False).returncode, 0)


class TransactionTests(Fixture):
    MOCKS = '''
service_stop() { printf 'stop\\n' >> "$WORK_DIR/calls"; }
service_start_check() { printf 'start\\n' >> "$WORK_DIR/calls"; }
'''

    def test_success_and_exact_restore(self):
        self.setup_config()
        self.out.chmod(0o640)
        original = self.out.read_bytes(), self.route.read_bytes()
        self.shell(self.MOCKS + '''
build_candidate 0 "$4" || exit 1
apply_candidate || exit 1
backup_list
TX_DIR=${BACKUPS[0]}
restore_check false && restore_files
''')
        self.assertEqual(original, (self.out.read_bytes(), self.route.read_bytes()))
        self.assertEqual(stat.S_IMODE(self.out.stat().st_mode), 0o640)
        for file in (self.root / "backups").glob("*/*.bak"):
            self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)

    def test_start_failure_automatically_restores(self):
        self.setup_config()
        before = self.out.read_bytes(), self.route.read_bytes()
        p = self.shell(self.MOCKS + '''
service_start_check() { printf 'start\\n' >> "$WORK_DIR/calls"; return 1; }
build_candidate 0 "$4" || exit 2
apply_candidate
''', check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(before, (self.out.read_bytes(), self.route.read_bytes()))
        self.assertIn('已恢复修改前', p.stdout)

    def test_partial_write_failure_rolls_back(self):
        self.setup_config()
        before = self.out.read_bytes(), self.route.read_bytes()
        p = self.shell(self.MOCKS + '''
eval "$(declare -f atomic_copy | sed '1s/atomic_copy/original_copy/')"
atomic_copy() { if [[ $1 == "$TASK_DIR/1.after" ]]; then return 1; fi; original_copy "$@"; }
build_candidate 0 "$4" || exit 2
apply_candidate
''', check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(before, (self.out.read_bytes(), self.route.read_bytes()))

    def test_drift_prevents_stopping_service(self):
        self.setup_config()
        p = self.shell(self.MOCKS + '''
build_candidate 0 "$4" || exit 2
printf '\\n' >> "${FILES[0]}"
apply_candidate
''', check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse((self.root / "calls").exists())

    def test_restore_refuses_later_edits(self):
        self.setup_config()
        p = self.shell(self.MOCKS + '''
build_candidate 0 "$4" || exit 2
apply_candidate || exit 2
backup_list; TX_DIR=${BACKUPS[0]}
printf '\\n' >> "${FILES[0]}"
restore_check false
''', check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('拒绝覆盖', p.stderr)

    def test_pending_empty_list(self):
        self.setup_config()
        self.shell('pending_check')

    def test_term_during_write_restores_original_files(self):
        self.setup_config()
        before = self.out.read_bytes(), self.route.read_bytes()
        result = self.shell(self.MOCKS + '''
trap cleanup EXIT
trap 'exit 143' TERM
eval "$(declare -f atomic_copy | sed '1s/atomic_copy/original_copy/')"
atomic_copy() {
    original_copy "$@" || return 1
    if [[ $1 == "$TASK_DIR/0.after" ]]; then kill -TERM "$$"; fi
}
build_candidate 0 "$4" || exit 2
apply_candidate
''', check=False)
        self.assertEqual(result.returncode, 143)
        self.assertEqual(before, (self.out.read_bytes(), self.route.read_bytes()))
        manifest = next((self.root / 'backups').glob('*/manifest.json'))
        self.assertEqual(json.loads(manifest.read_text())['status'], 'rolled_back')

    def test_exit_before_restore_confirmation_does_not_restore_pending_backup(self):
        self.setup_config()
        before = self.out.read_bytes(), self.route.read_bytes()
        self.shell(self.MOCKS + '''
build_candidate 0 "$4" || exit 2
tx_prepare || exit 2
TX_ARMED=false
trap cleanup EXIT
''')
        self.assertFalse((self.root / 'calls').exists())
        self.assertEqual(before, (self.out.read_bytes(), self.route.read_bytes()))
        manifest = next((self.root / 'backups').glob('*/manifest.json'))
        self.assertEqual(json.loads(manifest.read_text())['status'], 'prepared')

    def test_v1_existing_file_backups_can_be_restored(self):
        self.setup_config()
        before = self.out.read_bytes(), self.route.read_bytes()
        self.shell(self.MOCKS + '''
build_candidate 0 "$4" || exit 2
apply_candidate || exit 2
backup_list
TX_DIR=${BACKUPS[0]}
jq '.schema=1 | del(.config,.config_sha)' "$TX_DIR/manifest.json" > "$TASK_DIR/legacy.json"
cp "$TASK_DIR/legacy.json" "$TX_DIR/manifest.json"
restore_check false && restore_files
''')
        self.assertEqual(before, (self.out.read_bytes(), self.route.read_bytes()))


class CurlTests(Fixture):
    def test_real_curl_socks_auth_and_stdin_credentials(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(5)
        self.addCleanup(listener.close)
        evidence, errors = [], []

        def serve():
            try:
                conn, _ = listener.accept()
                with conn:
                    conn.settimeout(5)
                    version, size = exact(conn, 2)
                    self.assertIn(2, exact(conn, size))
                    conn.sendall(b"\x05\x02")
                    version, size = exact(conn, 2)
                    user = exact(conn, size)
                    password = exact(conn, exact(conn, 1)[0])
                    evidence.append((user.decode(), password.decode()))
                    conn.sendall(b"\x01\x00")
                    version, command, reserved, kind, size = exact(conn, 5)
                    evidence.append(exact(conn, size).decode())
                    exact(conn, 2)
                    conn.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
                    request = b""
                    while b"\r\n\r\n" not in request:
                        request += conn.recv(4096)
                    body = b"198.51.100.21"
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode() +
                                 b"\r\nConnection: close\r\n\r\n" + body)
            except BaseException as e:
                errors.append(str(e))

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        self.write(self.endpoint, dict(ENDPOINT, port=listener.getsockname()[1]))
        result = self.shell('probe_socks "$4" http://fixture.invalid/')
        thread.join(5)
        self.assertEqual(errors, [])
        self.assertEqual(evidence[0], (ENDPOINT['username'], ENDPOINT['password']))
        self.assertEqual(evidence[1], 'fixture.invalid')
        self.assertIn('198.51.100.21', result.stdout)
        self.assertNotIn(ENDPOINT['password'], result.stdout + result.stderr)


class TerminalTests(unittest.TestCase):
    def test_terminal_prompt_and_hidden_input(self):
        code = 'source "$1"; exec 9<>/dev/tty; ask NODE 11; n=$REPLY; secret_read PASSWORD; [[ $REPLY == fixture-password ]] && printf "\\nRESULT:%s\\n" "$n"'
        pid, fd = pty.fork()
        if pid == 0:
            os.execv('/bin/bash', ['bash', '-c', code, 'test', str(SCRIPT)])
        out = bytearray(); stage = 0
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if not select.select([fd], [], [], 0.1)[0]:
                    continue
                try: data = os.read(fd, 4096)
                except OSError: break
                if not data: break
                out.extend(data)
                if stage == 0 and b'NODE' in out: os.write(fd, b'\n'); stage=1
                if stage == 1 and b'PASSWORD' in out: os.write(fd, b'fixture-password\n'); stage=2
            self.assertIn(b'RESULT:11', out)
            self.assertNotIn(b'fixture-password', out)
        finally:
            os.close(fd)
            waited, _ = os.waitpid(pid, os.WNOHANG)
            if not waited:
                os.kill(pid, 9); os.waitpid(pid, 0)


if __name__ == '__main__':
    unittest.main()
