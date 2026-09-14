"""Core update details reflect actual installed files, including no-op and rollback."""
import unittest
import test_manager


class CoreReportTests(unittest.TestCase):
    setUp = test_manager.ManagerTests.setUp
    run_shell = test_manager.ManagerTests.run_shell
    mock_core = test_manager.ManagerTests.mock_core

    def fixture(self, old='v0.3.0', new='v0.4.0'):
        body = self.mock_core()
        (self.binary/'V2bX').write_text('#!/bin/sh\necho "V2bX '+old+' (fixture)"\n')
        return body + '''
systemctl() { printf '%s\\n' "$1" >> "$M_CONFIG/calls"; return 0; }
m_health() { return 0; }
m_prepare_core() {
    mkdir "$1/new"
    printf '#!/bin/sh\\necho "V2bX %s (fixture)"\\n' '''+new+''' > "$1/new/V2bX"
    chmod 755 "$1/new/V2bX"
    echo new > "$1/new/geoip.dat"; echo new > "$1/new/geosite.dat"
}
'''

    def test_update_reports_actual_versions_and_each_payload(self):
        result = self.run_shell(self.fixture()+'m_install_core')
        self.assertIn('v0.3.0 → v0.4.0', result.stdout)
        for name in ['V2bX 主程序', 'geoip.dat', 'geosite.dat', 'systemd 服务文件', '文件指纹', '备份：']:
            self.assertIn(name, result.stdout)
        self.assertIn('已更新', result.stdout)

    def test_same_version_with_new_geo_data_is_still_an_update(self):
        result = self.run_shell(self.fixture(old='v0.4.0')+'m_install_core')
        self.assertIn('v0.4.0 → v0.4.0', result.stdout)
        self.assertIn('V2bX 主程序 · 未变化', result.stdout)
        self.assertIn('GeoIP IP 规则库（geoip.dat） · 已更新', result.stdout)
        self.assertNotIn('无需更新', result.stdout)
        self.assertIn('stop', (self.cfg/'calls').read_text())

    def test_same_version_with_different_binary_is_not_treated_as_unchanged(self):
        body = self.fixture(old='v0.4.0')
        old_binary = self.binary/'V2bX'
        old_binary.write_text(old_binary.read_text()+'# previous build\n')
        result = self.run_shell(body+'m_install_core')
        self.assertIn('v0.4.0 → v0.4.0', result.stdout)
        self.assertIn('V2bX 主程序 · 已更新', result.stdout)
        self.assertNotIn('无需更新', result.stdout)

    def test_menu_waits_for_enter_after_showing_details(self):
        body = self.fixture()+'m_show_status() { :; }; m_menu'
        result = self.run_shell(body, '13\n\n\n19\n')
        self.assertIn('内核更新明细（更新前 → 更新后）', result.stdout)
        self.assertEqual(result.stderr.count('按回车返回菜单'), 1)
        self.assertEqual(result.stderr.count('请选择 [1-19]'), 2)

    def test_identical_release_reports_no_change_without_backup_or_restart(self):
        body = self.fixture(old='v0.4.0')
        for name in ['geoip.dat', 'geosite.dat']:
            (self.binary/name).write_text('new\n')
            (self.cfg/name).write_text('new\n')
        result = self.run_shell(body+'m_install_core')
        self.assertIn('无需更新', result.stdout)
        self.assertIn('v0.4.0 → v0.4.0', result.stdout)
        self.assertIn('geosite.dat） · 未变化', result.stdout)
        self.assertFalse((self.cfg/'manager-backups').exists())
        self.assertFalse((self.cfg/'calls').exists())

    def test_same_payload_but_stale_deployed_geo_data_is_repaired(self):
        body = self.fixture(old='v0.4.0')
        for name in ['geoip.dat', 'geosite.dat']:
            (self.binary/name).write_text('new\n')
        result = self.run_shell(body+'m_install_core')
        self.assertNotIn('无需更新', result.stdout)
        self.assertEqual((self.cfg/'geoip.dat').read_text(), 'new\n')

    def test_extra_release_file_change_is_not_skipped(self):
        body = self.fixture(old='v0.4.0')
        for name in ['geoip.dat', 'geosite.dat']:
            (self.binary/name).write_text('new\n')
            (self.cfg/name).write_text('new\n')
        (self.binary/'release-notes').write_text('old package file')
        result = self.run_shell(body+'m_install_core')
        self.assertNotIn('无需更新', result.stdout)
        self.assertIn('发布包文件集合 · 已更新', result.stdout)

    def test_rollback_reports_restored_version_instead_of_candidate(self):
        result = self.run_shell(self.fixture()+'m_health() { return 1; }; m_install_core', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('v0.3.0 → v0.3.0', result.stdout)
        self.assertNotIn('v0.3.0 → v0.4.0', result.stdout)
        self.assertIn('更新失败，已回滚', result.stdout)

    def test_download_failure_still_reports_installed_version(self):
        body = self.fixture()+'m_prepare_core() { return 1; }; m_install_core'
        result = self.run_shell(body, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('v0.3.0 → v0.3.0', result.stdout)
        self.assertIn('未应用更新', result.stdout)
        self.assertFalse((self.cfg/'calls').exists())
