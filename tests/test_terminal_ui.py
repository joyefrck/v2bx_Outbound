"""Exercise terminal output and echo, including terminals without color support."""
import os
from pathlib import Path
import pty
import select
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def terminal(body, reply=b'', env=None):
    master, slave = pty.openpty()
    environment = {key: value for key, value in os.environ.items() if key != 'NO_COLOR'}
    process = subprocess.Popen(
        ['bash', '-c', 'source "$1/v2bx-manager.sh"; exec 9<&0; ' + body, 'terminal', str(ROOT)],
        stdin=slave, stdout=slave, stderr=slave,
        env={**environment, 'TERM': 'xterm-256color', **(env or {})})
    os.close(slave)
    output = bytearray()
    try:
        deadline = time.monotonic() + 5
        sent = False
        while time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                output.extend(data)
                if reply and not sent and b'INPUT' in output:
                    os.write(master, reply)
                    sent = True
        code = process.wait(timeout=1)
        return code, output.decode().replace('\r\n', '\n')
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait()


class TerminalUiTests(unittest.TestCase):
    def test_tty_has_semantic_colors(self):
        code, output = terminal("m_banner; m_line 32 'READY'; m_line 33 'WAIT'; m_error 'FAILED' || true")
        self.assertEqual(code, 0)
        self.assertIn('\033[1;36m', output)
        self.assertIn('\033[32mREADY', output)
        self.assertIn('\033[33mWAIT', output)
        self.assertIn('\033[1;31m未完成：FAILED', output)

    def test_no_color_and_dumb_terminals(self):
        for env in ({'NO_COLOR': '1'}, {'TERM': 'dumb'}):
            with self.subTest(env=env):
                code, output = terminal('m_banner; source "$1/src/helper.sh"; show_menu', env=env)
                self.assertEqual(code, 0)
                self.assertNotIn('\033[', output)
                self.assertIn('SOCKS STATION', output)

    def test_redirected_menu_and_choices_are_plain_and_one_per_line(self):
        body = '''
source "$1/v2bx-manager.sh"
m_ask() { M_REPLY=17; }
m_installed() { return 1; }
m_menu
m_protocol_options '协议'
'''
        result = subprocess.run(['bash', '-c', body, 'test', str(ROOT)], capture_output=True, text=True,
                                env={**os.environ, 'TERM': 'xterm-256color'}, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('\033[', result.stdout)
        for text in ('  1. Shadowsocks\n', '  2. VLESS\n', '  8. AnyTLS\n',
                     '  18. SOCKS 出口管理\n', '节点与出口', '服务控制', '安装与维护'):
            self.assertIn(text, result.stdout)
        self.assertLess(result.stdout.index('V2bX 状态'), result.stdout.index('节点与出口'))

    def test_manager_api_key_echoes_and_round_trips(self):
        code, output = terminal('m_secret INPUT; [[ $M_REPLY == fixture-key ]] && echo ACCEPTED',
                                reply=b'fixture-key\n')
        self.assertEqual(code, 0)
        self.assertIn('fixture-key', output)
        self.assertIn('ACCEPTED', output)


if __name__ == '__main__':
    unittest.main()
