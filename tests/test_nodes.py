"""Incremental node management against private config/service fixtures."""
import hashlib
import json
from pathlib import Path
import unittest
import test_manager


class NodeTests(unittest.TestCase):
    setUp = test_manager.ManagerTests.setUp
    run_shell = test_manager.ManagerTests.run_shell
    def setup_nodes(self, count=2, kind='xray', named=False):
        ref = 'custom-core' if named else kind
        self.core = {'Type': kind, 'CustomOption': 'keep'}
        if named:
            self.core['Name'] = ref
        self.out = self.cfg / 'custom_outbound.json'
        self.route = self.cfg / 'route.json'
        self.origin = self.cfg / 'sing_origin.json'
        if kind == 'xray':
            self.core.update(OutboundConfigPath=str(self.out), RouteConfigPath=str(self.route))
        elif kind == 'sing':
            self.core.update(OriginalPath=str(self.origin))
        nodes = [{'Core': ref, 'ApiHost': 'https://panel.invalid', 'ApiKey': 'fixture-secret', 'NodeID': i+1,
                  'NodeType': 'vless', 'ListenIP': '0.0.0.0', 'CustomNodeOption': {'keep': True},
                  'CertConfig': {'CertMode': 'none', 'CustomTLS': 'keep'}} for i in range(count)]
        self.config = self.cfg / 'config.json'
        self.config.write_text(json.dumps({'Log': {'Level': 'error'}, 'Cores': [self.core], 'Nodes': nodes, 'Other': True}))
        self.config.chmod(0o640)
        self.tags = [f'[https://panel.invalid]-vless:{i+1}' for i in range(count)]
        self.managed = ['v2bx-socks-'+hashlib.sha256(t.encode()).hexdigest()[:12] for t in self.tags]
        out = [{'tag': 'direct', 'protocol': 'freedom'}]
        rules = [{'type': 'field', 'protocol': ['bittorrent'], 'outboundTag': 'block'}]
        if kind == 'xray':
            for tag, managed in zip(self.tags, self.managed):
                out.extend([{'tag': managed, 'protocol': 'socks', 'settings': {'secret': 'fixture'}},
                            {'tag': managed+'-udp', 'protocol': 'blackhole'}])
                rules.extend([{'type': 'field', 'inboundTag': [tag], 'network': 'udp', 'outboundTag': managed+'-udp'},
                              {'type': 'field', 'inboundTag': [tag], 'network': 'tcp,udp', 'outboundTag': managed}])
            rules.append({'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'direct'})
            self.out.write_text(json.dumps(out)); self.route.write_text(json.dumps({'rules': rules}))
        else:
            out = [{'tag': 'direct', 'type': 'direct'}]
            rules = [{'ip_is_private': True, 'action': 'reject'}]
            for tag, managed in zip(self.tags, self.managed):
                out.append({'tag': managed, 'type': 'socks', 'server': '127.0.0.1', 'password': 'fixture'})
                rules.extend([{'inbound': [tag], 'network': 'udp', 'action': 'reject'},
                              {'inbound': [tag], 'action': 'route', 'outbound': managed}])
            rules.append({'network': ['tcp', 'udp'], 'outbound': 'direct'})
            self.origin.write_text(json.dumps({'dns': {'keep': True}, 'outbounds': out, 'route': {'rules': rules}}))
        return '''
m_need_install() { return 0; }; m_lock() { return 0; }; m_standard_config() { return 0; }
systemctl() { printf '%s\\n' "$1" >> "$M_CONFIG/calls"; return 0; }
m_health() { return 0; }
'''

    def test_modify_selected_id_preserves_other_nodes_options_and_socks(self):
        code = self.setup_nodes(named=True)
        before = json.loads(self.config.read_text())
        routes = self.route.read_bytes(), self.out.read_bytes()
        result = self.run_shell(code+'m_edit', '1\n2\ny\n3\n25\n8\ny\n')
        after = json.loads(self.config.read_text())
        self.assertEqual(after['Nodes'][0], before['Nodes'][0])
        self.assertEqual(after['Nodes'][1]['NodeID'], 25)
        self.assertEqual(after['Nodes'][1]['Name'], self.tags[1])
        self.assertEqual(after['Nodes'][1]['CustomNodeOption'], {'keep': True})
        self.assertEqual(after['Cores'], before['Cores'])
        self.assertEqual(routes, (self.route.read_bytes(), self.out.read_bytes()))
        self.assertIn('第 2 个节点', result.stdout)
        self.assertNotIn('fixture-secret', result.stdout+result.stderr)

    def test_blank_value_keeps_node_and_does_not_restart(self):
        code = self.setup_nodes()
        original = self.config.read_bytes()
        self.run_shell(code+'m_edit', '1\n1\ny\n3\n\n2\n\n8\n')
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.cfg/'calls').exists())

    def test_cancel_target_or_save_does_not_modify(self):
        code = self.setup_nodes()
        original = self.config.read_bytes()
        for inputs in ['3\n2\nn\n', '3\n2\ny\nn\n', '1\n1\ny\n3\n9\n9\n']:
            self.run_shell(code+'m_edit', inputs)
            self.assertEqual(self.config.read_bytes(), original)
            self.assertFalse((self.cfg/'calls').exists())

    def test_duplicate_panel_node_rejected(self):
        code = self.setup_nodes()
        original = self.config.read_bytes()
        r = self.run_shell(code+'m_edit', '1\n2\ny\n3\n1\n8\ny\n', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.config.read_bytes(), original)

    def test_delete_only_selected_xray_node_and_managed_rules(self):
        code = self.setup_nodes()
        self.run_shell(code+'m_edit', '3\n1\ny\ny\n')
        after = json.loads(self.config.read_text())
        self.assertEqual([n['NodeID'] for n in after['Nodes']], [2])
        self.assertEqual(after['Cores'], [self.core])
        self.assertNotIn(self.managed[0], self.route.read_text()+self.out.read_text())
        self.assertIn(self.managed[1], self.route.read_text()+self.out.read_text())
        self.assertIn('bittorrent', self.route.read_text())

    def test_delete_selected_sing_node_retains_other_exit_and_dns(self):
        code = self.setup_nodes(kind='sing')
        self.run_shell(code+'m_edit', '3\n2\ny\ny\n')
        after = json.loads(self.origin.read_text())
        self.assertEqual(after['dns'], {'keep': True})
        self.assertNotIn(self.managed[1], self.origin.read_text())
        self.assertNotIn(self.tags[1], self.origin.read_text())
        self.assertIn(self.managed[0], self.origin.read_text())

    def test_delete_last_node_stops_service_without_health_check(self):
        code = self.setup_nodes(count=1)
        self.run_shell(code+'m_health() { return 9; }; m_edit', '3\n1\ny\ny\n')
        self.assertEqual(json.loads(self.config.read_text())['Nodes'], [])
        self.assertEqual((self.cfg/'calls').read_text(), 'is-active\nstop\n')

    def test_failure_restores_main_and_routes_with_modes(self):
        code = self.setup_nodes()
        self.route.chmod(0o640)
        originals = [p.read_bytes() for p in (self.config, self.out, self.route)]
        r = self.run_shell(code+'m_health() { return 1; }; m_edit', '3\n1\ny\ny\n', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(originals, [p.read_bytes() for p in (self.config, self.out, self.route)])
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.route.stat().st_mode & 0o777, 0o640)
        self.assertEqual(list(self.cfg.glob('.manager-nodes.*')), [])

    def test_add_to_named_core_preserves_existing_config_and_rules(self):
        code = self.setup_nodes(named=True)
        before = json.loads(self.config.read_text()); routes = self.out.read_bytes(), self.route.read_bytes()
        self.run_shell(code+'m_edit', '2\nhttps://new.invalid\nfixture-new-key\ny\n1\n33\n2\ny\nn\ny\n')
        after = json.loads(self.config.read_text())
        self.assertEqual(after['Nodes'][:2], before['Nodes'])
        self.assertEqual(after['Nodes'][2]['Core'], 'custom-core')
        self.assertEqual(after['Nodes'][2]['NodeID'], 33)
        self.assertEqual(after['Cores'], before['Cores'])
        self.assertEqual(routes, (self.out.read_bytes(), self.route.read_bytes()))

    def test_add_new_core_creates_only_missing_files(self):
        code = self.setup_nodes()
        before = self.route.read_bytes(), self.out.read_bytes()
        self.run_shell(code+'m_edit', '2\nhttps://new.invalid\nfixture-new-key\ny\n2\n33\n1\nn\nn\ny\n')
        after = json.loads(self.config.read_text())
        self.assertEqual([c['Type'] for c in after['Cores']], ['xray', 'sing'])
        self.assertTrue(self.origin.exists())
        self.assertEqual(before, (self.route.read_bytes(), self.out.read_bytes()))

    def test_add_new_core_failure_removes_new_files(self):
        code = self.setup_nodes()
        original = self.config.read_bytes()
        r = self.run_shell(code+'m_health() { return 1; }; m_edit', '2\nhttps://new.invalid\nfixture-key\ny\n2\n33\n1\nn\nn\ny\n', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(original, self.config.read_bytes())
        self.assertFalse(self.origin.exists())

    def test_secret_update_is_escaped_and_never_displayed(self):
        code = self.setup_nodes()
        secret = 'fixture-"new\\secret'
        r = self.run_shell(code+'m_edit', '1\n1\ny\n2\n'+secret+'\n8\ny\n')
        self.assertEqual(json.loads(self.config.read_text())['Nodes'][0]['ApiKey'], secret)
        self.assertNotIn(secret, r.stdout+r.stderr)

    def test_external_edit_while_confirming_is_not_overwritten(self):
        code = self.setup_nodes()
        r = self.run_shell(code+'''
m_confirm() {
    m_ask "$1" || return 1
    if [[ $1 == 确认备份* ]]; then printf '\\n' >> "$M_CONFIG/config.json"; fi
    [[ $M_REPLY == y ]]
}
m_edit
''', '3\n1\ny\ny\n', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(json.loads(self.config.read_text())['Nodes']), 2)
        self.assertFalse((self.cfg/'calls').exists())

    def test_shared_managed_rule_refuses_deletion(self):
        code = self.setup_nodes()
        route = json.loads(self.route.read_text())
        route['rules'][1]['inboundTag'].append('other-inbound')
        self.route.write_text(json.dumps(route))
        before = self.config.read_bytes(), self.route.read_bytes(), self.out.read_bytes()
        r = self.run_shell(code+'m_edit', '3\n1\ny\ny\n', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(before, (self.config.read_bytes(), self.route.read_bytes(), self.out.read_bytes()))

    def test_delete_with_empty_route_file_is_supported(self):
        code = self.setup_nodes()
        self.route.write_text('{}')
        self.run_shell(code+'m_edit', '3\n1\ny\ny\n')
        self.assertEqual(json.loads(self.route.read_text()), {})
        self.assertEqual(len(json.loads(self.config.read_text())['Nodes']), 1)

    def test_batch_add_reuses_shared_panel_and_preserves_all_existing_nodes(self):
        code = self.setup_nodes(named=True)
        before = json.loads(self.config.read_text())
        original_routes = self.out.read_bytes(), self.route.read_bytes()
        self.run_shell(code+'m_edit', '2\nhttps://new.invalid\nfixture-batch-key\ny\n1\n33\n2\ny\ny\n1\n34\n1\nn\nn\ny\n')
        after = json.loads(self.config.read_text())
        self.assertEqual(after['Nodes'][:2], before['Nodes'])
        self.assertEqual([node['NodeID'] for node in after['Nodes'][2:]], [33, 34])
        self.assertTrue(all(node['Core']=='custom-core' for node in after['Nodes']))
        self.assertEqual([node['ApiKey'] for node in after['Nodes'][2:]], ['fixture-batch-key']*2)
        self.assertEqual(after['Cores'], before['Cores'])
        self.assertEqual(original_routes, (self.out.read_bytes(), self.route.read_bytes()))

    def test_batch_add_can_use_different_panels(self):
        code = self.setup_nodes()
        self.run_shell(code+'m_edit', '2\nhttps://first.invalid\nfixture-first\nn\n1\n33\n1\nn\ny\nhttps://second.invalid\nfixture-second\n1\n34\n1\nn\nn\ny\n')
        nodes = json.loads(self.config.read_text())['Nodes']
        self.assertEqual([node['ApiHost'] for node in nodes[2:]], ['https://first.invalid','https://second.invalid'])
        self.assertEqual([node['ApiKey'] for node in nodes[2:]], ['fixture-first','fixture-second'])

    def test_duplicate_batch_is_rejected_as_a_whole(self):
        code = self.setup_nodes()
        original = self.config.read_bytes()
        r = self.run_shell(code+'m_edit', '2\nhttps://new.invalid\nfixture-key\ny\n1\n33\n1\nn\ny\n1\n33\n1\nn\nn\ny\n', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(original, self.config.read_bytes())
        self.assertFalse((self.cfg/'calls').exists())

    def test_interrupted_batch_does_not_save_first_node(self):
        code = self.setup_nodes()
        original = self.config.read_bytes(), self.out.read_bytes(), self.route.read_bytes()
        r = self.run_shell(code+'m_edit', '2\nhttps://new.invalid\nfixture-key\ny\n1\n33\n1\nn\ny\n', check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(original, (self.config.read_bytes(), self.out.read_bytes(), self.route.read_bytes()))
        self.assertFalse((self.cfg/'calls').exists())

    def test_batch_selects_among_multiple_existing_named_cores(self):
        code = self.setup_nodes(named=True)
        config = json.loads(self.config.read_text())
        config['Cores'].append({'Type':'xray','Name':'another-core','CustomOption':'also-keep'})
        self.config.write_text(json.dumps(config))
        self.run_shell(code+'m_edit', '2\nhttps://new.invalid\nfixture-key\ny\n1\n33\n1\nn\nn\n2\ny\n')
        after = json.loads(self.config.read_text())
        self.assertEqual(after['Nodes'][-1]['Core'], 'another-core')
        self.assertEqual(after['Cores'], config['Cores'])
