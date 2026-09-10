"""Exercise log following and Ctrl+C through a real controlling terminal."""
import errno
import os
from pathlib import Path
import pty
import select
import signal
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LogTerminalTests(unittest.TestCase):
    def test_menu_follows_logs_until_ctrl_c_then_returns_to_menu(self):
        with tempfile.TemporaryDirectory() as directory:
            command = Path(directory) / 'journalctl'
            command.write_text('''#!/bin/bash
printf 'LOG_START\\n'
case " $* " in *' -f '*) ;; *) exit 0;; esac
sleep 0.2
printf 'NEW_LOG_ARRIVED\\n'
while :; do sleep 1; done
''')
            command.chmod(0o755)
            pid, fd = pty.fork()
            if pid == 0:
                os.environ['PATH'] = directory + os.pathsep + os.environ['PATH']
                os.execvp('bash', ['bash', '-c', '''
source "$1/v2bx-manager.sh"
exec 9<>/dev/tty
m_banner() { printf 'MENU_READY\\n'; }
m_show_status() { :; }
m_section() { :; }
m_option() { :; }
m_menu
''', 'log-test', str(ROOT)])
            output = b''

            def until(marker, timeout=5):
                nonlocal output
                deadline = time.monotonic() + timeout
                while marker not in output and time.monotonic() < deadline:
                    if select.select([fd], [], [], .1)[0]:
                        try:
                            chunk = os.read(fd, 65536)
                        except OSError as exc:
                            if exc.errno != errno.EIO:
                                raise
                            break
                        if not chunk:
                            break
                        output += chunk
                self.assertIn(marker, output, output.decode(errors='replace'))

            try:
                until(b'MENU_READY')
                os.write(fd, b'5\n')
                until(b'NEW_LOG_ARRIVED')
                self.assertEqual(output.count(b'MENU_READY'), 1)
                output = b''
                os.write(fd, b'\x03')
                until(b'MENU_READY')
                os.write(fd, b'19\n')
            finally:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.close(fd)
                os.waitpid(pid, 0)
