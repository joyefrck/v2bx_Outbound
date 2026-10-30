"""HY2 isolation and transaction tests; JSON fixtures are also valid HY2 YAML.

The real YAML reader is tested in Go. These tests mock that read-only boundary,
never systemd, production settings or an external SOCKS account.
"""
import json
import shutil
import unittest
from pathlib import Path
from test_lightweight import Fixture, ENDPOINT
import test_lightweight


class Hy2SocksTests(Fixture):
    def shell(self, code, *args, **kwargs):
        return super().shell('hy2_read_json() { jq -e \'type=="object"\' "$1" >/dev/null && cat "$1"; };\n' + code, *args, **kwargs)

    def setup_hy2(self):
        self.hy2 = self.root / 'hy2config.yaml'
        self.original = {'quic': {'maxIdleTimeout': '30s'}, 'disableUDP': False,
                         'resolver': {'type': 'https', 'https': {'addr': 'https://1.1.1.1/dns-query'}},
                         'acl': {'geoip': '/custom/geoip.dat', 'inline': [
                             'direct(geosite:google)', 'reject(geosite:cn)', 'reject(geoip:cn)']},
                         'masquerade': {'type': 404}}
        self.write(self.hy2, self.original)
        self.write(self.config, {'Cores': [{'Type': 'hysteria2'}], 'Nodes': [
            {'Core': 'hysteria2', 'NodeType': 'hysteria2', 'NodeID': n,
             'ApiHost': 'https://panel.invalid', 'ApiKey': 'fixture-only',
             'Hysteria2ConfigPath': str(self.hy2)} for n in (201, 202)]})

    def managed(self, index=0):
        node = json.loads(self.config.read_text())['Nodes'][index]
        return Path(node['Hysteria2ConfigPath'])

    def apply(self, index=0):
        return self.shell(test_lightweight.TransactionTests.MOCKS + f'build_candidate {index} "$4" && apply_candidate')

    def test_shared_yaml_isolated_per_node_with_tcp_only_and_acl_preserved(self):
        self.setup_hy2()
        other = json.loads(self.config.read_text())['Nodes'][1]
        self.apply()
        result = json.loads(self.managed().read_text())
        self.assertNotEqual(self.managed(), self.hy2)
        self.assertEqual(json.loads(self.hy2.read_text()), self.original)
        self.assertEqual(json.loads(self.config.read_text())['Nodes'][1], other)
        self.assertTrue(result['disableUDP'])
        self.assertIn('reject(geosite:cn)', result['acl']['inline'])
        self.assertNotIn('direct(geosite:google)', result['acl']['inline'])
        self.assertEqual(result['quic'], self.original['quic'])
        self.assertEqual(result['resolver'], self.original['resolver'])
        self.assertEqual(result['outbounds'][0]['type'], 'socks5')
        self.assertEqual(result['outbounds'][0]['socks5']['password'], ENDPOINT['password'])
        self.assertRegex(result['outbounds'][0]['name'], r'^\w+$')

    def test_two_nodes_have_independent_exits(self):
        self.setup_hy2()
        self.apply()
        first = self.managed().read_bytes()
        self.write(self.endpoint, dict(ENDPOINT, host='192.0.2.10', udp=True))
        self.apply(1)
        self.assertNotEqual(self.managed(0), self.managed(1))
        self.assertEqual(self.managed(0).read_bytes(), first)
        self.assertFalse(json.loads(self.managed(1).read_text())['disableUDP'])

    def test_replace_then_remove_restores_original_routing(self):
        self.setup_hy2()
        self.apply()
        path = self.managed()
        self.write(self.endpoint, dict(ENDPOINT, host='192.0.2.11', udp=True))
        self.apply()
        self.assertEqual(self.managed(), path)
        self.shell(test_lightweight.TransactionTests.MOCKS + 'build_remove_candidate 0 && apply_candidate remove')
        self.assertEqual(json.loads(path.read_text()), self.original)
        self.assertEqual(json.loads(self.hy2.read_text()), self.original)

    def test_view_masks_password_and_does_not_write(self):
        self.setup_hy2()
        self.apply()
        path = self.managed()
        before = path.read_bytes(), self.config.read_bytes(), path.stat().st_mtime_ns
        r = self.shell('TASK_DIR=""; show_socks_config')
        self.assertIn('SOCKS 地址：127.0.0.1', r.stdout)
        self.assertIn('UDP：阻断', r.stdout)
        self.assertIn('密码：******', r.stdout)
        self.assertNotIn(ENDPOINT['password'], r.stdout + r.stderr)
        self.assertNotIn('fixture-only', r.stdout + r.stderr)
        self.assertEqual(before, (path.read_bytes(), self.config.read_bytes(), path.stat().st_mtime_ns))

    def test_failed_start_restores_main_and_removes_created_file(self):
        self.setup_hy2()
        before = self.config.read_bytes()
        r = self.shell(test_lightweight.TransactionTests.MOCKS + '''
service_start_check() { return 1; }
build_candidate 0 "$4" || exit 2
apply_candidate
''', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(list(self.root.glob('hy2-node-*.json')), [])

    def test_manual_restore_restores_main_and_removes_created_file(self):
        self.setup_hy2()
        before = self.config.read_bytes()
        self.shell(test_lightweight.TransactionTests.MOCKS + '''
build_candidate 0 "$4" && apply_candidate || exit 2
backup_list; TX_DIR=${BACKUPS[0]}
restore_check false && restore_files
''')
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(list(self.root.glob('hy2-node-*.json')), [])

    def test_source_drift_prevents_service_stop(self):
        self.setup_hy2()
        r = self.shell(test_lightweight.TransactionTests.MOCKS + '''
build_candidate 0 "$4" || exit 2
printf '\\n' >> "$WORK_DIR/hy2config.yaml"
apply_candidate
''', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.root/'calls').exists())

    def test_source_change_during_yaml_read_is_detected(self):
        self.setup_hy2()
        r = self.shell(test_lightweight.TransactionTests.MOCKS + '''
hy2_read_json() { cat "$1"; printf '\\n' >> "$WORK_DIR/hy2config.yaml"; }
build_candidate 0 "$4" || exit 2
apply_candidate
''', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.root/'calls').exists())

    def test_manually_changed_managed_route_is_not_overwritten(self):
        self.setup_hy2()
        self.apply()
        path = self.managed()
        data = json.loads(path.read_text())
        data['acl']['inline'].insert(0, 'direct(example.invalid)')
        self.write(path, data)
        before = path.read_bytes()
        self.assertNotEqual(self.build(check=False).returncode, 0)
        self.assertNotEqual(self.shell('build_remove_candidate 0', check=False).returncode, 0)
        self.assertEqual(path.read_bytes(), before)

    def test_external_acl_and_custom_proxy_are_refused(self):
        for update in ({'acl': {'file': '/custom/acl.txt'}},
                       {'outbounds': [{'name': 'custom', 'type': 'http'}]}):
            self.setup_hy2()
            self.write(self.hy2, dict(self.original, **update))
            self.assertNotEqual(self.build(check=False).returncode, 0)
            self.assertFalse((self.root/'calls').exists())

    def test_old_core_reader_failure_is_actionable_and_does_not_write(self):
        self.setup_hy2()
        before = self.config.read_bytes(), self.hy2.read_bytes()
        r = self.shell('hy2_read_json() { return 1; }; build_candidate 0 "$4"', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('HY2', r.stdout+r.stderr)
        self.assertEqual(before, (self.config.read_bytes(), self.hy2.read_bytes()))

    def test_partial_write_failure_restores_path_without_leaving_file(self):
        self.setup_hy2()
        before = self.config.read_bytes()
        r = self.shell(test_lightweight.TransactionTests.MOCKS + '''
build_candidate 0 "$4" || exit 2
eval "$(declare -f atomic_copy | sed '1s/atomic_copy/original_copy/')"
atomic_copy() { if [[ $1 == "$TASK_DIR/1.after" ]]; then return 1; fi; original_copy "$@"; }
apply_candidate
''', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(list(self.root.glob('hy2-node-*.json')), [])

    def test_preexisting_target_is_not_overwritten(self):
        self.setup_hy2()
        self.shell('build_candidate 0 "$4"')
        next_config = json.loads((self.task/'0.after').read_text())
        target = Path(next_config['Nodes'][0]['Hysteria2ConfigPath'])
        target.write_text('unrelated file')
        self.assertNotEqual(self.build(check=False).returncode, 0)
        self.assertEqual(target.read_text(), 'unrelated file')

    def test_shared_managed_path_alias_is_refused(self):
        self.setup_hy2()
        self.apply()
        alias = self.root/'alias.json'
        alias.hardlink_to(self.managed())
        config = json.loads(self.config.read_text())
        config['Nodes'][1]['Hysteria2ConfigPath'] = str(alias)
        self.write(self.config, config)
        self.assertNotEqual(self.build(check=False).returncode, 0)

    def test_view_detects_modified_route_without_exposing_password(self):
        self.setup_hy2()
        self.apply()
        data = json.loads(self.managed().read_text())
        data['acl']['inline'] = ['direct(all)']
        self.write(self.managed(), data)
        r = self.shell('TASK_DIR=""; show_socks_config')
        self.assertIn('无法读取 HY2', r.stdout)
        self.assertNotIn(ENDPOINT['password'], r.stdout+r.stderr)

    def test_manual_restore_refuses_later_edit_to_main(self):
        self.setup_hy2()
        self.apply()
        r = self.shell('''
backup_list; TX_DIR=${BACKUPS[0]}
printf '\\n' >> "$CONFIG_PATH"
restore_check false
''', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('主配置已被其他操作修改', r.stderr)

    @unittest.skipUnless(shutil.which('flock'), 'Linux flock verified on Linux')
    def test_background_worker_applies_isolation(self):
        self.setup_hy2()
        self.shell(test_lightweight.TransactionTests.MOCKS + '''
SELF_PATH=$1
healthy() { return 0; }; discover() { return 0; }
build_candidate 0 "$4" || exit 2
prepare_job apply || exit 3
job_worker "$JOB_DIR"
''')
        self.assertEqual(json.loads(self.managed().read_text())['outbounds'][0]['type'], 'socks5')
        job = next((self.root/'socks-helper-jobs').glob('job-*'))
        self.assertEqual(json.loads((job/'result.json').read_text())['status'], 'succeeded')
        self.assertFalse((job/'v2bx-socks.work').exists())
