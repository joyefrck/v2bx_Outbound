"""APT recovery uses isolated fixtures; unit tests never alter host sources."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DependencyTests(unittest.TestCase):
    def run_apt(self, distro='debian', version='11', mode='recover'):
        with tempfile.TemporaryDirectory(prefix='v2bx-apt-test-') as directory:
            result = subprocess.run(['bash', '-c', '''
source "$1"
mode=$4
apt-get() {
    local arg sources='' lists='' action=''
    for arg in "$@"; do
        case $arg in
            Dir::Etc::sourcelist=*) sources=${arg#*=};;
            Dir::State::lists=*) lists=${arg#*=};;
            update|install) action=$arg;;
        esac
    done
    printf 'APT:%s:%s\n' "$action" "${sources:+isolated}"
    if [[ -z $sources ]]; then
        [[ $mode == normal ]] || return 100
    else
        [[ -d $lists ]] || return 91
        cat "$sources"
        case $mode:$action in fail-update:update|fail-install:install) return 100;; esac
    fi
}
m_apt_dependencies "$2" "$3"
''', 'apt-test', str(ROOT / 'src/manager/common.sh'), distro, version, mode],
                capture_output=True, text=True, timeout=5, env={**os.environ, 'TMPDIR': directory})
            self.assertEqual(list(Path(directory).iterdir()), [])
            return result

    def test_normal_apt_needs_no_recovery(self):
        result = self.run_apt(mode='normal')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'APT:update:\nAPT:install:\n')

    def test_bullseye_failure_uses_scoped_official_sources(self):
        result = self.run_apt()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('APT:update:isolated', result.stdout)
        self.assertIn('APT:install:isolated', result.stdout)
        self.assertIn('https://deb.debian.org/debian bullseye main', result.stdout)
        self.assertIn('deb [check-valid-until=no] https://security.debian.org/debian-security bullseye-security main', result.stdout)
        self.assertNotIn('trusted=yes', result.stdout)
        self.assertNotIn('bullseye-backports', result.stdout)

    def test_other_systems_do_not_use_bullseye_sources(self):
        for distro, version in (('debian', '12'), ('ubuntu', '22.04')):
            result = self.run_apt(distro, version)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('isolated', result.stdout)

    def test_recovery_failures_propagate_and_clean_up(self):
        for mode in ('fail-update', 'fail-install'):
            result = self.run_apt(mode=mode)
            self.assertNotEqual(result.returncode, 0)
            if mode == 'fail-update':
                self.assertNotIn('APT:install:isolated', result.stdout)


if __name__ == '__main__':
    unittest.main()
