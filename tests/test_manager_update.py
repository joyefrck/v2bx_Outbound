"""Menu tool updates use a pinned, checked installer and reopen the installed menu."""
import hashlib
import json
import unittest
import test_manager


class ManagerUpdateTests(unittest.TestCase):
    setUp = test_manager.ManagerTests.setUp
    run_shell = test_manager.ManagerTests.run_shell

    def fixture(self):
        self.commit = 'a' * 40
        self.downloads = self.root / 'downloads'
        self.downloads.mkdir()
        (self.downloads/'head.json').write_text(json.dumps({'object': {'sha': self.commit}}))
        self.installed = self.root / 'installed-manager'
        self.installed.write_text('#!/bin/bash\necho OLD-MENU\n')
        (self.downloads/'manager').write_text(
            '#!/bin/bash\nif [[ ${1:-} == --version ]]; then echo 3.6.0; else echo MENU:3.6.0; fi\n')
        installer = self.downloads/'install.sh'
        installer.write_text('''#!/bin/bash
set -eu
[[ $1 == --tools-only && $2 == --commit && $3 == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
cp "$FIXTURE_UPDATE_ROOT/downloads/manager" "$FIXTURE_UPDATE_ROOT/installed-manager"
''')
        (self.downloads/'SHA256SUMS').write_text(hashlib.sha256(installer.read_bytes()).hexdigest()+'  install.sh\n')
        return '''
export FIXTURE_UPDATE_ROOT=$2
M_SELF=$2/installed-manager
MANAGER_VERSION=3.5.2
m_show_status() { :; }
m_fetch() {
    printf '%s\\n' "$1" >> "$FIXTURE_UPDATE_ROOT/urls"
    case $1 in
        */git/ref/heads/main) cp "$FIXTURE_UPDATE_ROOT/downloads/head.json" "$2";;
        *) cp "$FIXTURE_UPDATE_ROOT/downloads/${1##*/}" "$2";;
    esac
}
m_install_core() { echo UNEXPECTED-CORE; return 99; }
systemctl() { echo UNEXPECTED-SERVICE; return 99; }
'''

    def test_menu_12_updates_tools_and_reopens_installed_version(self):
        r = self.run_shell(self.fixture()+'m_menu', '12\ny\n')
        self.assertIn('MENU:3.6.0', r.stdout)
        self.assertIn('3.5.2 → 3.6.0', r.stdout)
        self.assertNotIn('UNEXPECTED-', r.stdout)
        urls = (self.root/'urls').read_text().splitlines()
        self.assertEqual(len(urls), 3)
        self.assertTrue(all('/'+self.commit+'/' in url for url in urls[1:]))

    def test_cancel_does_not_reload_or_replace_installed_menu(self):
        body = self.fixture()
        before = self.installed.read_bytes()
        r = self.run_shell(body+'m_menu', '12\nn\n19\n')
        self.assertNotIn('OLD-MENU', r.stdout)
        self.assertNotIn('MENU:3.6.0', r.stdout)
        self.assertEqual(self.installed.read_bytes(), before)

    def test_bad_checksum_keeps_old_menu_and_reports_failure(self):
        body = self.fixture()
        before = self.installed.read_bytes()
        (self.downloads/'install.sh').write_text('exit 99\n')
        r = self.run_shell(body+'m_menu', '12\n19\n')
        self.assertEqual(self.installed.read_bytes(), before)
        self.assertNotIn('MENU:3.6.0', r.stdout)
        self.assertIn('校验失败', r.stderr)

    def test_failed_installer_never_reports_success_or_reloads(self):
        body = self.fixture()
        installer = self.downloads/'install.sh'
        installer.write_text('#!/bin/bash\nexit 1\n')
        (self.downloads/'SHA256SUMS').write_text(hashlib.sha256(installer.read_bytes()).hexdigest()+'  install.sh\n')
        r = self.run_shell(body+'m_menu', '12\ny\n19\n')
        self.assertNotIn('MENU:3.6.0', r.stdout)
        self.assertNotIn('管理工具已更新', r.stdout)
        self.assertIn('更新失败', r.stderr)
