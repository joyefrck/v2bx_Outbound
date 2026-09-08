"""Installer failure tests use temporary paths; no system install or network."""
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VALID = b'#!/usr/bin/env bash\n# V2bX SOCKS Helper fixture\nprintf "fixture-version\\n"\n'


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v2bx-installer-test-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.downloads = self.directory / 'downloads'
        self.downloads.mkdir()
        self.destination = self.directory / 'bin' / 'v2bx-socks'
        self.destination.parent.mkdir()
        self.payload(VALID)

    def payload(self, data):
        (self.downloads / 'v2bx-socks.sh').write_bytes(data)
        (self.downloads / 'SHA256SUMS').write_text(hashlib.sha256(data).hexdigest() + '  v2bx-socks.sh\n')

    def install(self):
        result = subprocess.run(['bash', '-c', '''
source "$1"
fixtures=$2
download_file() { cp "$fixtures/${1##*/}" "$2"; }
trap cleanup_install EXIT
install_helper "$3" https://fixture.invalid
''', 'installer-test', str(ROOT / 'install.sh'), str(self.downloads), str(self.destination)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(list(self.destination.parent.glob('.v2bx-socks-install.*')), [])
        return result

    def test_install_creates_executable_command(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), VALID)
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o755)
        self.assertEqual(subprocess.check_output([str(self.destination)]), b'fixture-version\n')

    def test_update_replaces_previous_helper(self):
        self.destination.write_bytes(b'#!/bin/bash\n# V2bX SOCKS Helper previous\n')
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.destination.read_bytes(), VALID)

    def test_checksum_mismatch_preserves_previous_helper(self):
        self.destination.write_bytes(VALID)
        (self.downloads / 'v2bx-socks.sh').write_bytes(VALID + b'echo corrupted\n')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('校验失败', result.stderr)
        self.assertEqual(self.destination.read_bytes(), VALID)

    def test_download_failure_preserves_previous_helper(self):
        self.destination.write_bytes(VALID)
        (self.downloads / 'SHA256SUMS').unlink()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('下载失败', result.stderr)
        self.assertEqual(self.destination.read_bytes(), VALID)

    def test_invalid_bash_preserves_previous_helper(self):
        self.destination.write_bytes(VALID)
        self.payload(b'#!/bin/bash\nif then\n')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('语法检查失败', result.stderr)
        self.assertEqual(self.destination.read_bytes(), VALID)

    def test_existing_unrelated_command_is_not_overwritten(self):
        self.destination.write_bytes(b'#!/bin/bash\nprintf unrelated\n')
        before = self.destination.read_bytes()
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(self.destination.read_bytes(), before)

    def test_symlink_is_not_followed(self):
        other = self.directory / 'other'
        other.write_bytes(VALID)
        self.destination.symlink_to(other)
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(other.read_bytes(), VALID)

    def test_release_artifact_and_checksum_match_source(self):
        data = (ROOT / 'v2bx-socks.sh').read_bytes()
        self.assertEqual(data, (ROOT / 'src/helper.sh').read_bytes())
        modules = ['common', 'templates', 'config', 'core-install', 'nodes', 'menu']
        source = b''.join((ROOT / 'src/manager' / (name + '.sh')).read_bytes() for name in modules)
        self.assertEqual((ROOT / 'v2bx-manager.sh').read_bytes(), source)
        checksums = dict(line.split()[::-1] for line in (ROOT / 'SHA256SUMS').read_text().splitlines())
        for name, digest in checksums.items():
            self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), digest)


if __name__ == '__main__':
    unittest.main()
