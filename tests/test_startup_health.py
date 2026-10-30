"""First boot: ACME's temporary HTTP listener is not a ready HY2 node."""
from test_lightweight import Fixture


class StartupHealthTests(Fixture):
    def setUp(self):
        super().setUp()
        self.write(self.config, {'Nodes': [{
            'Core': 'hysteria2', 'NodeType': 'hysteria2', 'NodeID': 218,
            'CertConfig': {'CertMode': 'http', 'CertFile': 'fullchain.cer', 'KeyFile': 'cert.key'},
        }], 'Cores': [{'Type': 'hysteria2'}]})

    mock = r'''
TEST_CONFIG=$CONFIG_PATH
TEST_ROOT=$WORK_DIR
printf '0\n' > "$TEST_ROOT/tick"
systemctl() {
    printf '%s\n' 'LoadState=loaded' 'ActiveState=active' 'SubState=running'
    printf 'MainPID=%s\nNRestarts=%s\nExecMainStartTimestampMonotonic=%s\n' "${TEST_PID:-1234}" "${TEST_RESTARTS:-0}" "${TEST_START:-100}"
    printf 'ExecStart={ path=/usr/local/V2bX/V2bX ; argv[]=/usr/local/V2bX/V2bX server -c %s ; }\n' "$TEST_CONFIG"
    printf 'WorkingDirectory=%s\n' "$TEST_ROOT"
}
sleep() {
    local tick
    read -r tick < "$TEST_ROOT/tick"
    tick=$((tick+1)); printf '%s\n' "$tick" > "$TEST_ROOT/tick"
    if [[ ${TEST_ISSUE_CERT:-false} == true && $tick -ge 45 ]]; then
        printf cert > "$TEST_ROOT/fullchain.cer"; printf key > "$TEST_ROOT/cert.key"
    fi
    if [[ ${TEST_CRASH:-false} == true && $tick -ge 3 ]]; then
        TEST_PID=5678; TEST_RESTARTS=1; TEST_START=200
    fi
}
ss() {
    local tick
    read -r tick < "$TEST_ROOT/tick"
    if [[ ${TEST_LISTENER:-transition} == udp || $tick -ge 46 ]]; then
        printf 'udp UNCONN 0 0 *:1001 *:* users:(("V2bX",pid=%s,fd=9))\n' "${TEST_PID:-1234}"
    elif [[ ${TEST_LISTENER:-transition} == http || $tick -lt 45 ]]; then
        printf 'tcp LISTEN 0 4096 *:80 *:* users:(("V2bX",pid=%s,fd=7))\n' "${TEST_PID:-1234}"
    fi
}
export TEST_CONFIG TEST_ROOT
export -f systemctl sleep ss
'''

    def manager(self, extra):
        return self.shell(self.mock + r'''
source "${1%/*}/manager/common.sh"
M_HELPER=$1
''' + extra)

    def test_http_challenge_is_not_hy2_readiness_even_with_existing_cert(self):
        for certificate_exists in (False, True):
            with self.subTest(certificate_exists=certificate_exists):
                if certificate_exists:
                    (self.root/'fullchain.cer').write_text('cert')
                    (self.root/'cert.key').write_text('key')
                result = self.shell(self.mock + r'''
TEST_LISTENER=http
discover
healthy 0 && exit 99
printf '%s\n' "$HEALTH_ERROR"
''')
                self.assertIn('未就绪', result.stdout)

    def test_udp_listener_does_not_hide_pending_certificate(self):
        result = self.shell(self.mock + r'''
TEST_LISTENER=udp
discover
healthy 0 && exit 99
printf '%s\n' "$HEALTH_ERROR"
''')
        self.assertIn('证书', result.stdout)

    def test_empty_private_key_path_is_not_lost_as_trailing_newline(self):
        self.write(self.config, {'Nodes': [{'NodeType': 'hysteria2', 'CertConfig': {
            'CertMode': 'http', 'CertFile': 'fullchain.cer', 'KeyFile': ''}}]})
        (self.root/'fullchain.cer').write_text('cert')
        self.shell(self.mock + r'''
TEST_LISTENER=udp
discover
healthy 0 && exit 99
exit 0
''')

    def test_manager_waits_for_first_certificate_and_udp_past_30_seconds(self):
        self.manager(r'''
export TEST_ISSUE_CERT=true
m_health || exit 98
read -r tick < "$TEST_ROOT/tick"
((tick>=51)) || exit 97
''')

    def test_helper_start_waits_for_first_certificate_and_udp(self):
        self.shell(self.mock + r'''
TEST_ISSUE_CERT=true
discover
service_start_check || exit 98
read -r tick < "$TEST_ROOT/tick"
((tick>=61)) || exit 97
''')

    def test_restart_during_certificate_request_is_still_a_failure(self):
        self.manager(r'''
export TEST_ISSUE_CERT=true TEST_CRASH=true
m_health && exit 99
read -r tick < "$TEST_ROOT/tick"
((tick<45)) || exit 98
''')

    def test_pending_certificate_times_out_without_accepting_http_listener(self):
        self.manager(r'''
export TEST_LISTENER=http
m_health && exit 99
read -r tick < "$TEST_ROOT/tick"
((tick>=180 && tick<=181)) || exit 98
''')

    def test_restart_between_initial_probe_and_observation_is_not_accepted(self):
        self.write(self.config, {'Nodes': [{'Core': 'xray', 'NodeType': 'vless'}]})
        self.manager(r'''
eval "$(declare -f systemctl | sed '1s/systemctl/original_systemctl/')"
systemctl() {
    if [[ -f $TEST_ROOT/restarted ]]; then TEST_PID=5678; TEST_RESTARTS=1; TEST_START=200; fi
    original_systemctl "$@"
}
ss() {
    local pid=1234
    [[ ! -f $TEST_ROOT/restarted ]] || pid=5678
    touch "$TEST_ROOT/restarted"
    printf 'tcp LISTEN 0 4096 *:443 *:* users:(("V2bX",pid=%s,fd=9))\n' "$pid"
}
export -f systemctl original_systemctl ss
m_health && exit 99
exit 0
''')

    def test_all_automatic_certificate_files_must_be_ready_in_mixed_config(self):
        self.write(self.config, {'Nodes': [
            {'Core': 'xray', 'NodeType': 'vless'},
            {'Core': 'hysteria2', 'NodeType': 'hysteria2', 'CertConfig': {
                'CertMode': 'dns', 'CertFile': 'fullchain.cer', 'KeyFile': 'cert.key'}},
        ]})
        (self.root/'fullchain.cer').write_text('cert')
        self.shell(self.mock + r'''
TEST_LISTENER=udp
discover
healthy 0 && exit 99
printf key > "$TEST_ROOT/cert.key"
healthy 0
''')

    def test_transient_gap_during_stability_check_is_retried(self):
        self.write(self.config, {'Nodes': [{'Core': 'xray', 'NodeType': 'vless'}]})
        self.manager(r'''
ss() {
    local tick; read -r tick < "$TEST_ROOT/tick"
    ((tick!=3)) || return 0
    printf 'tcp LISTEN 0 4096 *:443 *:* users:(("V2bX",pid=1234,fd=9))\n'
}
export -f ss
m_health || exit 98
read -r tick < "$TEST_ROOT/tick"
((tick>=9)) || exit 97
''')
