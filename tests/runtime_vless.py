import copy
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from types import SimpleNamespace

from runtime_xray import free_port, json_bytes

UUID = '11111111-1111-4111-8111-111111111111'


def wait_for(check, label, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (OSError, subprocess.SubprocessError):
            pass
        time.sleep(.15)
    raise AssertionError(label)


def stop_process(process, log):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    log.close()


def main(binary, mihomo):
    binary = str(Path(binary).resolve())
    with tempfile.TemporaryDirectory(prefix='v2bx-vless-') as folder, ExitStack() as cleanup:
        folder = Path(folder)
        cert, key = folder/'cert.pem', folder/'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=fixture.test', '-addext', 'subjectAltName=DNS:fixture.test'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        state = {'config': None, 'users': [{'id': 7, 'uuid': UUID}], 'reports': [], 'fetches': 0}

        class Target(BaseHTTPRequestHandler):
            def do_GET(self):
                body = b'VLESS-INTEGRATION-' + b'x' * 4096
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        class Panel(BaseHTTPRequestHandler):
            def do_GET(self):
                path = urlparse(self.path).path.rsplit('/', 1)[-1]
                if path == 'config':
                    state['fetches'] += 1
                    value = state['config']
                elif path == 'user':
                    value = {'users': state['users']}
                else:
                    value = {'alive': {}}
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json_bytes(value))

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                if urlparse(self.path).path.endswith('/push'):
                    state['reports'].append(json.loads(body))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{}')

            def log_message(self, *args):
                pass

        def serve(handler, tls=False, alpn=False):
            server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
            if tls:
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.minimum_version = ssl.TLSVersion.TLSv1_3
                if alpn:
                    context.set_alpn_protocols(['h2'])
                context.load_cert_chain(cert, key)
                server.socket = context.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            cleanup.callback(server.server_close)
            cleanup.callback(server.shutdown)
            return server

        target, panel = serve(Target, True), serve(Panel)
        camouflage = SimpleNamespace(server_port=free_port())
        camouflage_log = open(folder/'camouflage.log', 'wb')
        camouflage_process = subprocess.Popen(['openssl', 's_server', '-accept', f'127.0.0.1:{camouflage.server_port}', '-cert', str(cert), '-key', str(key), '-tls1_3', '-groups', 'X25519', '-alpn', 'h2', '-www', '-quiet'], stdout=camouflage_log, stderr=subprocess.STDOUT)
        cleanup.callback(stop_process, camouflage_process, camouflage_log)
        pair = json.loads(subprocess.check_output([binary, 'vlessenc', '--json']))
        reality = subprocess.check_output([binary, 'x25519'], input=b'n\n').decode()
        private = reality.split('Private key: ')[1].splitlines()[0]
        public = reality.split('Public key: ')[1].splitlines()[0]
        port = free_port()
        common = {'server_port': port, 'network': 'tcp', 'network_settings': {}, 'tls': 1, 'flow': '', 'base_config': {'pull_interval': 1, 'push_interval': 1}}
        state['config'] = dict(common, encryption='none')

        def launch(name, config):
            path = folder/(name+'.json')
            path.write_bytes(json_bytes(config))
            log = open(folder/(name+'.log'), 'wb')
            process = subprocess.Popen([binary, 'server', '-c', str(path), '--watch=false'], cwd=folder, stdout=log, stderr=subprocess.STDOUT)
            cleanup.callback(stop_process, process, log)
            return process

        server = launch('server', {'Log': {'Level': os.getenv('V2BX_TEST_LOG', 'error')}, 'Cores': [{'Type': 'xray', 'Log': {'Level': os.getenv('V2BX_TEST_LOG', 'error')}, 'AssetPath': str(folder)}], 'Nodes': [{'Core': 'xray', 'ApiHost': f'http://127.0.0.1:{panel.server_port}', 'ApiKey': 'fixture', 'NodeID': 1, 'NodeType': 'vless', 'ListenIP': '127.0.0.1', 'AllowPrivateNetwork': True, 'CertConfig': {'CertMode': 'file', 'CertFile': str(cert), 'KeyFile': str(key)}}]})

        def client(network='tcp', security='tls', encryption='none', flow=''):
            socks = free_port()
            proxy = {'name': 'fixture', 'type': 'vless', 'server': '127.0.0.1', 'port': port, 'uuid': UUID, 'tls': security != 'none', 'servername': 'fixture.test', 'skip-cert-verify': True, 'client-fingerprint': 'chrome', 'flow': flow, 'encryption': encryption, 'network': network}
            if security == 'reality':
                proxy['reality-opts'] = {'public-key': public, 'short-id': '0123456789abcdef', 'support-x25519mlkem768': True}
            if network == 'xhttp':
                proxy['xhttp-opts'] = {'path': '/fixture', 'mode': 'auto', 'x-padding-bytes': '100-200'}
            path = folder/f'mihomo-{socks}.json'
            path.write_bytes(json_bytes({'mixed-port': socks, 'mode': 'rule', 'log-level': os.getenv('V2BX_TEST_LOG', 'error'), 'tls': {'custom-certifactes': [cert.read_text()]}, 'proxies': [proxy], 'rules': ['MATCH,fixture']}))
            log = open(folder/f'mihomo-{socks}.log', 'wb')
            process = subprocess.Popen([str(Path(mihomo).resolve()), '-d', str(folder/f'mihomo-home-{socks}'), '-f', str(path)], cwd=folder, stdout=log, stderr=subprocess.STDOUT)
            cleanup.callback(stop_process, process, log)
            return socks, process

        def request(socks):
            result = subprocess.run(['curl', '-q', '-ksSf', '--max-time', '3', '--noproxy', '', '--proxy', f'socks5h://127.0.0.1:{socks}', f'https://127.0.0.1:{target.server_port}/'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            return result.returncode == 0 and result.stdout.startswith(b'VLESS-INTEGRATION-')

        try:
            socks, _ = client()
            wait_for(lambda: request(socks), 'old panel TLS node failed')
            for network, security, flow, encrypted in [('tcp', 'tls', '', True), ('tcp', 'none', '', True), ('tcp', 'reality', 'xtls-rprx-vision', False), ('tcp', 'reality', 'xtls-rprx-vision', True), ('xhttp', 'tls', '', True), ('xhttp', 'reality', '', True)]:
                config = dict(common, network=network, tls={'reality': 2, 'tls': 1, 'none': 0}[security], flow=flow)
                if encrypted:
                    config['decryption'] = pair['decryption']
                else:
                    config['encryption'] = 'none'
                if network == 'xhttp':
                    config['network_settings'] = {'path': '/fixture', 'mode': 'auto', 'extra': {'xPaddingBytes': '100-200'}}
                if security == 'reality':
                    config['tls_settings'] = {'dest': '127.0.0.1', 'server_name': 'fixture.test', 'server_port': str(camouflage.server_port), 'private_key': private, 'short_id': '0123456789abcdef'}
                state['config'] = config
                socks, _ = client(network, security, pair['encryption'] if encrypted else 'none', flow)
                wait_for(lambda: request(socks), f'{network}/{security}/{flow} encrypted connection failed')
                valid = copy.deepcopy(config)
                before = state['fetches']
                state['config'] = dict(config, decryption='invalid-sensitive-value')
                wait_for(lambda: state['fetches'] >= before + 2, 'invalid config was not retried')
                wait_for(lambda: request(socks), 'invalid candidate removed old listener')
                state['config'] = valid
                print(f'PASS: {network}/{security}/{flow or "no-flow"} {"encrypted" if encrypted else "legacy"} HTTPS; invalid candidate preserved listener and retried')
            wait_for(lambda: any('7' in item and all(n > 0 for n in item['7']) for item in state['reports']), 'traffic was not assigned to user 7')
            state['users'] = []
            wait_for(lambda: not request(socks), 'last user revocation failed')
            assert server.poll() is None, 'server exited on invalid candidate'
            print('PASS: old panel compatibility, user traffic attribution and last-user revocation')
        except BaseException:
            for path in folder.glob('*.log'):
                print(path.name + ': ' + path.read_text(errors='replace')[-5000:], file=sys.stderr)
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('server_binary')
    parser.add_argument('mihomo_binary')
    args = parser.parse_args()
    main(args.server_binary, args.mihomo_binary)
