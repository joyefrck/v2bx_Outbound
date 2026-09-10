import json
import os
import subprocess
from test_lightweight import Fixture, SCRIPT


class EndpointInputTests(Fixture):
    def ask(self, values):
        result = subprocess.run(['bash', '-c', r'''
source "$1"
TASK_DIR=$2
umask 077
exec 9<&0
ask() {
    printf '%s\n' "$1" >&2
    IFS= read -r REPLY || return 1
    [[ -n $REPLY ]] || REPLY=${2:-}
}
probe_socks() { validate_endpoint "$1" && printf 'PROBE_CALLED\n'; }
ask_endpoint
''', 'endpoint-test', str(SCRIPT), str(self.task)],
                                input='\n'.join(values) + '\n', capture_output=True, text=True)
        return result

    def saved(self):
        return json.loads((self.task / 'endpoint.json').read_text())

    def test_enter_defaults_to_quick_input(self):
        result = self.ask(['', '192.0.2.10:44739:sample-user:sample-password'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.saved(), dict(host='192.0.2.10', port=44739,
                         username='sample-user', password='sample-password', udp=False))
        self.assertIn('PROBE_CALLED', result.stdout)
        self.assertNotIn('sample-password', result.stdout + result.stderr)
        self.assertEqual(os.stat(self.task / 'endpoint.json').st_mode & 0o777, 0o600)

    def test_password_keeps_colons_spaces_and_shell_characters(self):
        password = 'a:b:$`"\\ value '
        result = self.ask(['1', 'proxy.example:1080:sample-user:' + password])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.saved()['password'], password)

    def test_bracketed_ipv6(self):
        result = self.ask(['1', '[2001:db8::1]:1080:user:pass'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.saved()['host'], '2001:db8::1')

    def test_manual_authentication_and_default_port(self):
        result = self.ask(['2', '192.0.2.20', '', 'manual-user', 'manual:password'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.saved()['port'], 1080)
        self.assertEqual(self.saved()['username'], 'manual-user')
        self.assertEqual(self.saved()['password'], 'manual:password')

    def test_manual_without_authentication(self):
        result = self.ask(['2', '192.0.2.20', '1080', ''])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.saved()['username'], '')
        self.assertEqual(self.saved()['password'], '')

    def test_invalid_quick_input_never_probes(self):
        for value in ['192.0.2.10:1080:user', '192.0.2.10:0:user:pass',
                      '192.0.2.10:65536:user:pass', '192.0.2.10:no:user:pass',
                      '192.0.2.10:1080::pass', '192.0.2.10:1080:user:',
                      '2001:db8::1:1080:user:pass', 'https://proxy.example:1080:user:pass',
                      '192.0.2.10:1080:user:bad\tpassword']:
            with self.subTest(value=value):
                result = self.ask(['1', value])
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('PROBE_CALLED', result.stdout)

    def test_invalid_mode_and_eof_do_not_probe(self):
        for values in [['3'], ['1']]:
            result = self.ask(values)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('PROBE_CALLED', result.stdout)
