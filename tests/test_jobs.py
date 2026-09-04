"""Private fixture configs only; never modifies the host's V2bX service."""
import json
import os
import shutil
import subprocess
import unittest
from test_lightweight import Fixture
import test_lightweight


class JobTests(Fixture):
    def prep(self):
        self.setup_config()
        return test_lightweight.TransactionTests.MOCKS + '''
SELF_PATH=$1
healthy() { return 0; }
discover() { return 0; }
build_candidate 0 "$4" || exit 2
'''

    def test_failed_dispatch_never_stops_service_and_cleans_credentials(self):
        before = self.prep()
        result = self.shell(before + '''
systemd-run() { return 1; }
submit_job apply
''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'calls').exists())
        job = next((self.root / 'socks-helper-jobs').glob('job-*'))
        self.assertFalse((job / 'v2bx-socks.work').exists())
        self.assertEqual(json.loads((job / 'result.json').read_text())['status'], 'failed')

    @unittest.skipUnless(shutil.which('flock'), 'Linux flock verified on Linux')
    def test_worker_applies_staged_candidate_and_cleans_secrets(self):
        self.shell(self.prep() + '''
prepare_job apply || exit 2
job_worker "$JOB_DIR"
''')
        job = next((self.root / 'socks-helper-jobs').glob('job-*'))
        self.assertEqual(json.loads((job / 'result.json').read_text())['status'], 'succeeded')
        self.assertFalse((job / 'v2bx-socks.work').exists())
        self.assertIn('socks', [o.get('protocol') for o in json.loads(self.out.read_text())])
        self.assertEqual((self.root / 'calls').read_text(), 'stop\nstart\n')

    @unittest.skipUnless(shutil.which('flock'), 'Linux flock verified on Linux')
    def test_worker_failure_rolls_back(self):
        prefix = self.prep()
        original = self.out.read_bytes(), self.route.read_bytes()
        result = self.shell(prefix + '''
service_start_check() { return 1; }
prepare_job apply || exit 2
job_worker "$JOB_DIR"
''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(original, (self.out.read_bytes(), self.route.read_bytes()))
        job = next((self.root / 'socks-helper-jobs').glob('job-*'))
        self.assertEqual(json.loads((job / 'result.json').read_text())['status'], 'failed')
        self.assertFalse((job / 'v2bx-socks.work').exists())

    @unittest.skipUnless(shutil.which('flock'), 'Linux flock verified on Linux')
    def test_drift_after_submission_refused_before_stop(self):
        result = self.shell(self.prep() + '''
prepare_job apply || exit 2
printf '\\n' >> "$CONFIG_PATH"
job_worker "$JOB_DIR"
''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'calls').exists())

    @unittest.skipUnless(shutil.which('flock'), 'Linux flock verified on Linux')
    def test_background_restore(self):
        prefix = self.prep()
        original = self.out.read_bytes(), self.route.read_bytes()
        self.shell(prefix + '''
apply_candidate || exit 2
backup_list; TX_DIR=${BACKUPS[0]}
prepare_job restore || exit 2
job_worker "$JOB_DIR"
''')
        self.assertEqual(original, (self.out.read_bytes(), self.route.read_bytes()))

    def test_result_query_distinguishes_interrupted_job(self):
        result = self.shell(self.prep() + '''
prepare_job apply || exit 2
systemctl() { return 1; }
show_last_job
''')
        self.assertIn('未确认完成', result.stdout)

    def test_active_job_blocks_another_menu(self):
        result = self.shell(self.prep() + """
prepare_job apply || exit 2
systemctl() { printf 'active\\n'; }
check_running_jobs
""", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('正在后台处理', result.stdout)
        self.assertFalse((self.root / 'calls').exists())

    def test_launch_command_has_no_secrets_or_terminal_pipe(self):
        result = self.shell(self.prep() + '''
systemd-run() { printf '%s\\n' "$@" > "$WORK_DIR/dispatch"; }
exec 8>"$WORK_DIR/lock"
submit_job apply
[[ $BACKGROUND_SUBMITTED == true ]] || exit 2
[[ ! -e /proc/$$/fd/8 ]] || exit 3
''')
        args = (self.root / 'dispatch').read_text()
        self.assertIn('--collect', args)
        self.assertIn('--worker', args)
        self.assertNotIn('--pipe', args)
        self.assertNotIn('password', args)
        self.assertNotIn('test:user', args)


if __name__ == '__main__':
    unittest.main()


@unittest.skipUnless(os.environ.get('V2BX_SYSTEMD_TEST') == '1', 'Opt-in isolated real systemd test')
class SystemdDisconnectTests(Fixture):
    def test_ssh_parent_hangup_does_not_abort_apply(self):
        import time
        self.setup_config()
        from test_lightweight import SCRIPT
        snapshot = self.root / 'helper.sh'
        overrides = '''
discover() { WORK_DIR=${CONFIG_PATH%/*}; BACKUP_ROOT=$WORK_DIR/backups; }
healthy() { return 0; }
service_stop() {
    printf 'stop\\n' >> "$WORK_DIR/calls"
    kill -HUP "$(cat "$WORK_DIR/menu.pid")"
    sleep 1
}
service_start_check() { printf 'start\\n' >> "$WORK_DIR/calls"; }
'''
        original = SCRIPT.read_text()
        marker = 'if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi'
        snapshot.write_text(original.replace(marker, overrides + '\n' + marker))
        snapshot.chmod(0o700)
        code = '''
source "$1"
SELF_PATH=$1; TASK_DIR=$2; CONFIG_PATH=$3; WORK_DIR=${CONFIG_PATH%/*}; BACKUP_ROOT=$WORK_DIR/backups
umask 077
trap cleanup EXIT
trap 'exit 143' HUP
printf '%s' "$$" > "$WORK_DIR/menu.pid"
exec 8>"$WORK_DIR/.v2bx-socks.lock"
flock -n 8 || exit 2
build_candidate 0 "$4" || exit 3
submit_job apply || exit 4
wait_job
'''
        proc = subprocess.Popen(['bash', '-c', code, 'test-menu', str(snapshot), str(self.task), str(self.config), str(self.endpoint)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        stdout, stderr = proc.communicate(timeout=30)
        self.assertEqual(proc.returncode, 143, stdout + stderr)
        job = next((self.root / 'socks-helper-jobs').glob('job-*'))
        deadline = time.monotonic() + 25
        while not (job / 'result.json').exists() and time.monotonic() < deadline:
            time.sleep(.1)
        self.assertTrue((job / 'result.json').exists(), (job / 'output.log').read_text())
        self.assertEqual(json.loads((job / 'result.json').read_text())['status'], 'succeeded', (job / 'output.log').read_text())
        self.assertEqual((self.root / 'calls').read_text(), 'stop\nstart\n')
        self.assertIn('socks', [o.get('protocol') for o in json.loads(self.out.read_text())])
