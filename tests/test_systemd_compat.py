"""Model RHEL 7.9's ENXIO for explicitly requested absent properties."""
from test_lightweight import Fixture


class LegacySystemdTests(Fixture):
    legacy = r'''
TEST_CONFIG=$CONFIG_PATH
systemctl() {
    local arg missing=false
    for arg in "$@"; do
        [[ $arg != *NRestarts* ]] || missing=true
    done
    printf 'LoadState=loaded\nActiveState=active\nSubState=running\nMainPID=1234\n'
    printf 'ExecMainStartTimestampMonotonic=%s\n' "${START_TIME:-100}"
    printf 'ExecStart={ path=/usr/local/V2bX/V2bX ; argv[]=/usr/local/V2bX/V2bX server -c %s ; }\n' "$TEST_CONFIG"
    printf 'WorkingDirectory=%s\n' "${TEST_CONFIG%/*}"
    printf 'Environment=private-fixture-value\n'
    [[ $missing == false ]]
}
ss() { printf 'tcp LISTEN users:((V2bX,pid=1234,fd=9))\n'; }
'''

    def test_legacy_discovery_and_health_without_restart_counter(self):
        self.setup_config()
        self.shell(self.legacy + '\ndiscover && healthy 0')

    def test_manager_health_uses_legacy_compatible_discovery(self):
        self.setup_config()
        self.shell(self.legacy + r'''
sleep() { :; }
export TEST_CONFIG
export -f systemctl ss sleep
source "${1%/*}/manager/common.sh"
M_HELPER=$1
m_health
''')

    def test_service_state_filters_unrelated_properties(self):
        result = self.shell(self.legacy + '\nservice_state')
        self.assertNotIn('Environment=', result.stdout)
        self.assertIn('ExecMainStartTimestampMonotonic=100', result.stdout)

    def test_timestamp_change_detects_restart_without_counter(self):
        result = self.shell(self.legacy + r'''
sleep() { START_TIME=200; }
healthy 1 && exit 99
printf '%s\n' "$HEALTH_ERROR"
''')
        self.assertIn('发生重启', result.stdout)

    def test_bus_failure_is_not_accepted_as_healthy_partial_output(self):
        result = self.shell(r'''
systemctl() {
    printf 'ActiveState=active\nSubState=running\nMainPID=1234\n'
    printf 'Failed to get D-Bus connection: fixture error\n' >&2
    return 1
}
service_state
''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Failed to get D-Bus connection', result.stderr)
