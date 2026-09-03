"""Updater uses fixture downloads; no GitHub request or system file is changed."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMMIT = 'a' * 40


def script(version, body='printf "NEW-MENU\\n"\n'):
    return f'#!/usr/bin/env bash\n# V2bX SOCKS Helper fixture\nVERSION={version}\n{body}'.encode()


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v2bx-update-tests-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / 'v2bx-socks.work'
        self.work.mkdir(mode=0o700)
        self.downloads = self.root / 'downloads'
        self.downloads.mkdir()
        (self.downloads / 'head.json').write_text(json.dumps({'object': {'sha': COMMIT}}))
        self.target = self.root / 'v2bx-socks'
        self.old = script('1.0.0', 'printf "OLD-MENU\\n"\n')
        self.target.write_bytes(self.old)
        self.target.chmod(0o750)
        self.payload(script('1.1.0'))

    def payload(self, data):
        self.new = data
        (self.downloads / 'v2bx-socks.sh').write_bytes(data)
        (self.downloads / 'SHA256SUMS').write_text(hashlib.sha256(data).hexdigest() + '  v2bx-socks.sh\n')

    def run_update(self, before='', after=''):
        result = subprocess.run(['bash', '-c', '''
source "$1"
TASK_DIR=$2
SELF_PATH=$3
fixtures=$4
VERSION=1.0.0
umask 077
service_stop() { exit 71; }
service_start_check() { exit 72; }
confirm() { printf 'confirmed\\n' >> "${SELF_PATH}.confirm"; return 0; }
update_fetch() {
    printf '%s\\n' "$1" >> "${SELF_PATH}.urls"
    case $1 in
        https://api.github.com/repos/joyefrck/v2bx_Outbound/git/ref/heads/main) cp "$fixtures/head.json" "$2";;
        *) cp "$fixtures/${1##*/}" "$2";;
    esac
}
''' + before + '\nupdate_helper\nresult=$?\n' + after + '\nexit "$result"',
                                 'update-test', str(ROOT / 'src/helper.sh'), str(self.work),
                                 str(self.target), str(self.downloads)], capture_output=True, text=True, timeout=10)
        return result

    def test_update_preserves_old_backup_and_mode(self):
        result = self.run_update(after='[[ $RELOAD_HELPER == true ]] || exit 75')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_bytes(), self.new)
        backups = list(self.root.glob('v2bx-socks.bak-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), self.old)
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o750)
        urls = (self.root / 'v2bx-socks.urls').read_text().splitlines()
        self.assertEqual(urls[1:], [f'https://raw.githubusercontent.com/joyefrck/v2bx_Outbound/{COMMIT}/{name}'
                                    for name in ('v2bx-socks.sh', 'SHA256SUMS')])

    def test_same_version_and_content_is_not_reinstalled(self):
        self.payload(self.old)
        result = self.run_update(after='[[ $RELOAD_HELPER == false ]] || exit 75')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('已是最新版本', result.stdout)
        self.assertFalse((self.root / 'v2bx-socks.confirm').exists())

    def test_same_version_content_change_can_be_updated(self):
        self.payload(script('1.0.0'))
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('文件内容有更新', result.stdout)
        self.assertEqual(self.target.read_bytes(), self.new)

    def test_older_version_does_not_downgrade(self):
        self.payload(script('0.9.9'))
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('不降级', result.stdout)
        self.assertEqual(self.target.read_bytes(), self.old)
        self.assertFalse((self.root / 'v2bx-socks.confirm').exists())

    def test_cancel_does_not_replace_file(self):
        result = self.run_update(before='confirm() { return 1; }')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_bytes(), self.old)
        self.assertEqual(list(self.root.glob('v2bx-socks.bak-*')), [])

    def test_bad_checksum_keeps_old_version(self):
        (self.downloads / 'v2bx-socks.sh').write_bytes(self.new + b'# changed\n')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('校验失败', result.stderr)
        self.assertEqual(self.target.read_bytes(), self.old)

    def test_download_failure_keeps_old_version(self):
        (self.downloads / 'SHA256SUMS').unlink()
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('下载失败', result.stderr)
        self.assertEqual(self.target.read_bytes(), self.old)

    def test_invalid_commit_is_rejected(self):
        (self.downloads / 'head.json').write_text('{"object":{"sha":"not-a-commit"}}')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.old)
        self.assertEqual(len((self.root / 'v2bx-socks.urls').read_text().splitlines()), 1)

    def test_invalid_bash_is_not_executed(self):
        self.payload(script('1.1.0', 'if then\n'))
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('语法', result.stderr)
        self.assertEqual(self.target.read_bytes(), self.old)

    def test_target_changed_during_confirmation_is_preserved(self):
        result = self.run_update(before='confirm() { printf "external-change\\n" > "$SELF_PATH"; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('已被其他操作修改', result.stderr)
        self.assertEqual(self.target.read_text(), 'external-change\n')

    def test_failure_after_replacement_restores_original_script(self):
        result = self.run_update(before='''
eval "$(declare -f atomic_copy | sed '1s/atomic_copy/original_copy/')"
atomic_copy() {
    original_copy "$@" || return 1
    [[ $1 != "$TASK_DIR/update-script" ]]
}
''', after='[[ $RELOAD_HELPER == false ]] || exit 75')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.old)

    def test_version_is_read_without_executing_downloaded_code(self):
        self.payload(script('$(printf UNEXPECTED-EXEC >&2)'))
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('版本号格式无效', result.stderr)
        self.assertNotIn('UNEXPECTED-EXEC', result.stdout + result.stderr)
        self.assertEqual(self.target.read_bytes(), self.old)

    def test_version_comparison_is_numeric(self):
        self.old = script('1.9.0')
        self.target.write_bytes(self.old)
        self.payload(script('1.10.0'))
        result = self.run_update(before='VERSION=1.9.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_bytes(), self.new)

    def test_exit_reopens_new_script_and_cleans_temp_files(self):
        result = self.run_update(before='trap cleanup EXIT; exec 8>/dev/null; exec 9>/dev/null')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('NEW-MENU', result.stdout)
        self.assertFalse(self.work.exists())

    @unittest.skipUnless(shutil.which('flock'), 'Linux flock is verified in CI')
    def test_reload_releases_old_menu_lock(self):
        self.payload(script('1.1.0', 'flock -n "$UPDATE_TEST_LOCK" -c "printf LOCK-RELEASED"\n'))
        result = self.run_update(before='''
export UPDATE_TEST_LOCK="${SELF_PATH}.lock"
exec 8>"$UPDATE_TEST_LOCK"
flock -n 8 || exit 76
exec 9>/dev/null
trap cleanup EXIT
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('LOCK-RELEASED', result.stdout)
