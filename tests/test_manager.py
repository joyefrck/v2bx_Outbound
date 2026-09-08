"""Unified workflows use private fixtures and mocked service/download boundaries."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='v2bx-manager-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cfg = self.root / 'config'
        self.cfg.mkdir()
        self.binary = self.root / 'binary'
        self.binary.mkdir()
        self.helper = ROOT / 'v2bx-socks.sh'

    def run_shell(self, body, stdin='', check=True):
        result = subprocess.run(['bash', '-c', '''
source "$1/v2bx-manager.sh"
M_CONFIG=$2/config; M_BINARY=$2/binary; M_UNIT=$2/V2bX.service
M_HELPER=$1/v2bx-socks.sh
m_ask() { printf '%s：' "$1" >&2; IFS= read -r M_REPLY; }
m_secret() { IFS= read -r M_REPLY; }
''' + body, 'test-manager', str(ROOT), str(self.root)], input=stdin, capture_output=True, text=True, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_menu_service_status_and_autostart(self):
        cases = [
            ('loaded', 'active', 'running', 'enabled', '已运行', '是'),
            ('loaded', 'inactive', 'dead', 'disabled', '未运行', '否'),
            ('loaded', 'failed', 'failed', 'enabled', '启动失败', '是'),
            ('loaded', 'activating', 'auto-restart', 'enabled', '重启中', '是'),
            ('loaded', 'activating', 'start', 'enabled', '启动中', '是'),
            ('loaded', 'deactivating', 'stop', 'disabled', '停止中', '否'),
            ('loaded', 'active', 'exited', 'static', '未运行', '否'),
            ('not-found', 'inactive', 'dead', 'not-found', '服务未注册', '否'),
            ('loaded', 'active', 'running', 'enabled-runtime', '已运行', '否（仅本次运行期间启用）'),
        ]
        for load, active, sub, enabled, status, autostart in cases:
            with self.subTest(active=active, sub=sub, enabled=enabled):
                r = self.run_shell('''
m_installed() { return 0; }
systemctl() {
    case $1 in
        show) printf '%s\\n' 'LoadState=%s' 'ActiveState=%s' 'SubState=%s';;
        is-enabled) echo '%s'; [[ '%s' == enabled ]];;
        *) return 99;;
    esac
}
m_menu
''' % ('%s', load, active, sub, enabled, enabled), '17\n')
                self.assertIn('V2bX 状态：' + status, r.stdout)
                self.assertIn('是否开机自启：' + autostart, r.stdout)
        r = self.run_shell('m_installed() { return 1; }; systemctl() { echo unexpected; }; m_menu', '17\n')
        self.assertIn('V2bX 状态：未安装', r.stdout)
        self.assertNotIn('unexpected', r.stdout)
        r = self.run_shell('m_installed() { return 0; }; systemctl() { return 1; }; m_menu', '17\n')
        self.assertIn('V2bX 状态：未知', r.stdout)
        self.assertIn('是否开机自启：未知', r.stdout)

    def test_menu_refreshes_status_after_service_action(self):
        r = self.run_shell('''
m_installed() { return 0; }
fixture_active=active; fixture_sub=running
systemctl() {
    case $1 in
        show) printf 'LoadState=loaded\\nActiveState=%s\\nSubState=%s\\n' "$fixture_active" "$fixture_sub";;
        is-enabled) echo enabled;;
        *) return 99;;
    esac
}
m_service() { [[ $1 == stop ]] || return 1; fixture_active=inactive; fixture_sub=dead; }
m_menu
''', '5\n17\n')
        self.assertEqual(r.stdout.count('V2bX 状态：'), 2)
        self.assertLess(r.stdout.index('V2bX 状态：已运行'), r.stdout.index('V2bX 状态：未运行'))

    def test_existing_install_never_installs_or_generates(self):
        result = self.run_shell('''
m_installed() { return 0; }
m_install_core() { echo unexpected-install; return 1; }
m_generate() { echo unexpected-generate; return 1; }
m_install_flow
''')
        self.assertNotIn('unexpected', result.stdout)

    def test_first_install_skip_configuration(self):
        r = self.run_shell('''
m_installed() { return 1; }
m_install_core() { echo installed; }
m_install_flow
''', '\n')
        self.assertIn('节点尚未配置', r.stdout)

    def test_first_install_optional_socks(self):
        for answer, expected in [('n', False), ('y', True)]:
            r = self.run_shell('''
m_installed() { return 1; }
m_install_core() { echo installed; }
m_generate() { echo '{"Cores":[{"Type":"xray"}]}' > "$M_CONFIG/config.json"; }
m_health() { return 0; }
m_socks() { echo opened-socks; }
m_install_flow
''', 'y\n' + answer + '\n')
            self.assertEqual('opened-socks' in r.stdout, expected)

    def test_failed_install_does_not_prompt_for_configuration(self):
        r = self.run_shell('''
m_installed() { return 1; }; m_install_core() { return 1; }
m_confirm() { echo unexpected-prompt; }
m_install_flow
''', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('unexpected', r.stdout)

    def test_cancelled_wizard_does_not_offer_socks(self):
        self.run_shell('''
m_installed() { return 1; }; m_install_core() { return 0; }
m_generate() { return 2; }; m_offer_socks() { echo unexpected; return 1; }
m_install_flow
''', 'y\n')

    def test_unhealthy_service_does_not_prompt_socks(self):
        r = self.run_shell('''
m_health() { return 1; }
m_confirm() { echo unexpected; }
m_offer_socks
''', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('unexpected', r.stdout)

    def test_unsupported_core_does_not_open_socks(self):
        (self.cfg / 'config.json').write_text('{"Cores":[{"Type":"hysteria2"}]}')
        r = self.run_shell('m_health() { return 0; }; m_offer_socks')
        self.assertIn('不支持 SOCKS', r.stdout)

    def test_json_escaping_and_no_secret_output(self):
        key = 'test-"key\\secret'
        r = self.run_shell('''
mkdir "$M_CONFIG/candidate"
check_ipv6_support() { printf 0; }
m_build_config "$M_CONFIG/candidate"
''', '\n'.join(['https://panel.invalid', key, 'y', '1', '10', '2', 'y', 'n']) + '\n')
        data = json.loads((self.cfg / 'candidate/config.json').read_text())
        self.assertEqual(data['Nodes'][0]['ApiKey'], key)
        self.assertNotIn(key, r.stdout + r.stderr)
        self.assertEqual(data['Nodes'][0]['NodeType'], 'vless')
        self.assertEqual(data['Cores'][0]['Type'], 'xray')

    def test_mixed_cores_reset_node_tls_and_protocol_choices(self):
        self.run_shell('''mkdir "$M_CONFIG/candidate"; check_ipv6_support() { printf 0; }; m_build_config "$M_CONFIG/candidate"''',
                       '\n'.join(['https://panel.invalid', 'fixture-key', 'y',
                                  '2', '1', '8', '1', 'node.invalid', 'y',
                                  '1', '2', '1', 'n', 'n']) + '\n')
        data = json.loads((self.cfg / 'candidate/config.json').read_text())
        self.assertEqual(data['Nodes'][0]['CertConfig']['CertMode'], 'http')
        self.assertEqual(data['Nodes'][1]['CertConfig']['CertMode'], 'none')
        self.assertEqual({c['Type'] for c in data['Cores']}, {'xray', 'sing'})

    def test_invalid_xray_protocol_refused(self):
        r = self.run_shell('mkdir "$M_CONFIG/candidate"; m_build_config "$M_CONFIG/candidate"',
                           'https://panel.invalid\nfixture-key\ny\n1\n1\n8\n', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.cfg / 'candidate/config.json').exists())

    def mock_transaction(self):
        return '''
m_need_install() { return 0; }; m_lock() { return 0; }; m_standard_config() { return 0; }
systemctl() { printf '%s\\n' "$1" >> "$M_CONFIG/calls"; return 0; }
m_build_config() {
    local f
    for f in config.json custom_outbound.json route.json sing_origin.json; do echo '{}' > "$1/$f"; done
    echo quic: > "$1/hy2config.yaml"
}
'''

    def test_configuration_failure_restores_files_permissions_and_absence(self):
        f = self.cfg / 'config.json'
        f.write_text('{"original":true}')
        f.chmod(0o640)
        r = self.run_shell(self.mock_transaction() + 'm_health() { return 1; }; m_generate', 'y\ny\n', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(json.loads(f.read_text()), {'original': True})
        self.assertEqual(f.stat().st_mode & 0o777, 0o640)
        self.assertFalse((self.cfg / 'route.json').exists())
        self.assertEqual(list(self.cfg.glob('.manager-config.*')), [])

    def test_configuration_success_backs_up_every_overwritten_file(self):
        files = ['config.json', 'custom_outbound.json', 'route.json', 'sing_origin.json', 'hy2config.yaml']
        for f in files:
            (self.cfg / f).write_text('old:' + f)
        self.run_shell(self.mock_transaction() + 'm_health() { return 0; }; m_generate', 'y\ny\n')
        backup = next((self.cfg / 'manager-backups').glob('config-*'))
        for f in files:
            self.assertEqual((backup / f).read_text(), 'old:' + f)
            self.assertEqual((self.cfg / f).stat().st_mode & 0o777, 0o600)

    @unittest.skipUnless(shutil.which('flock'), 'requires Linux flock')
    def test_helper_active_job_blocks_regeneration(self):
        self.run_shell('''
mkdir -p "$M_CONFIG/socks-helper-jobs/job-test"
echo '{"unit":"v2bx-socks-job-test"}' > "$M_CONFIG/socks-helper-jobs/job-test/job.json"
systemctl() { echo active; }; export -f systemctl
m_lock && exit 9
exit 0
''')
        self.assertFalse((self.cfg / 'manager-backups').exists())

    @unittest.skipUnless(shutil.which('flock'), 'requires Linux flock')
    def test_held_helper_lock_blocks_manager(self):
        self.run_shell('''
exec 6>"$M_CONFIG/.v2bx-socks.lock"; flock -n 6
m_lock && exit 9
exit 0
''')

    def mock_core(self):
        (self.binary / 'V2bX').write_text('#!/bin/sh\necho old\n')
        (self.binary / 'V2bX').chmod(0o755)
        (self.root / 'V2bX.service').write_text('old-unit')
        for f in ['geoip.dat', 'geosite.dat']:
            (self.cfg / f).write_text('old-' + f)
        return '''
m_lock() { return 0; }; m_standard_config() { return 0; }
systemctl() { return 0; }
m_prepare_core() { mkdir "$1/new"; printf '#!/bin/sh\\necho new\\n' > "$1/new/V2bX"; chmod 755 "$1/new/V2bX"; echo new > "$1/new/geoip.dat"; echo new > "$1/new/geosite.dat"; }
'''

    def test_failed_core_download_preserves_binary_without_stopping(self):
        code = self.mock_core() + '''
systemctl() { echo unexpected-stop; }
m_prepare_core() { return 1; }
m_install_core
'''
        r = self.run_shell(code, check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('unexpected', r.stdout)
        self.assertIn('old', (self.binary / 'V2bX').read_text())

    def test_failed_core_health_restores_binary_geo_and_unit(self):
        r = self.run_shell(self.mock_core() + 'm_health() { return 1; }; m_install_core', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('old', (self.binary / 'V2bX').read_text())
        self.assertEqual((self.cfg / 'geoip.dat').read_text(), 'old-geoip.dat')
        self.assertEqual((self.root / 'V2bX.service').read_text(), 'old-unit')

    def test_core_update_preserves_stopped_service_and_configuration(self):
        code = self.mock_core() + '''
systemctl() { [[ $1 != is-active ]] || return 1; echo "$1" >> "$M_CONFIG/calls"; }
m_health() { echo unexpected-health; return 1; }
m_install_core
'''
        (self.cfg / 'config.json').write_text('{"keep":"fixture"}')
        self.run_shell(code)
        self.assertIn('new', (self.binary / 'V2bX').read_text())
        self.assertNotIn('start', (self.cfg / 'calls').read_text())
        self.assertEqual(json.loads((self.cfg / 'config.json').read_text()), {'keep': 'fixture'})


class ToolBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='v2bx-tools-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.manager = self.root / 'V2bX'
        self.helper = self.root / 'helper'
        (self.root / 'aliases').mkdir()
        self.alias = self.root / 'aliases/v2bx'
        self.license = self.root / 'LICENSE'
        self.downloads = self.root / 'downloads'
        self.downloads.mkdir()
        for f in ['v2bx-manager.sh', 'v2bx-socks.sh', 'LICENSE.MPL-2.0', 'SHA256SUMS']:
            shutil.copy(ROOT / f, self.downloads / f)
        self.manager.write_text('#!/bin/bash\n# V2bX Integrated Manager old\n')
        self.helper.write_text('#!/bin/bash\n# V2bX SOCKS Helper old\n')

    def install(self, prefix=''):
        return subprocess.run(['bash', '-c', '''
source "$1/install.sh"
download_file() { cp "$2ROOT/downloads/${1##*/}" "$2"; }
''' .replace('$2ROOT', '$FIXTURE') + prefix + '''
FIXTURE=$2
install_tools "$2/V2bX" "$2/helper" "$2/aliases/v2bx" "$2/LICENSE" https://fixture.invalid
''', 'bundle-test', str(ROOT), str(self.root)], capture_output=True, text=True, timeout=15)

    def test_bundle_installs_menu_alias_and_helper(self):
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.manager.read_bytes(), (ROOT / 'v2bx-manager.sh').read_bytes())
        self.assertEqual(self.alias.resolve(), self.manager.resolve())
        self.assertIn('18. SOCKS', self.manager.read_text())

    def test_bad_second_payload_preserves_both_old_commands(self):
        before = self.manager.read_bytes(), self.helper.read_bytes()
        (self.downloads / 'v2bx-socks.sh').write_text('corrupt')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(before, (self.manager.read_bytes(), self.helper.read_bytes()))

    def test_partial_replacement_failure_restores_entire_bundle(self):
        before = self.manager.read_bytes(), self.helper.read_bytes()
        r = self.install('''
replace_tool_file() {
    if [[ $1 == */v2bx-socks.sh ]]; then return 1; fi
    cp -p "$1" "$2"
}
''')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(before, (self.manager.read_bytes(), self.helper.read_bytes()))
        self.assertFalse(self.alias.exists())

    def test_unrelated_alias_is_preserved(self):
        self.alias.write_text('unrelated')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(self.alias.read_text(), 'unrelated')


if __name__ == '__main__':
    unittest.main()
