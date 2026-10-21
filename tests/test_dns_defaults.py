import json
import unittest

import test_manager
import test_nodes


class DnsDefaultsTests(unittest.TestCase):
    setUp = test_manager.ManagerTests.setUp
    run_shell = test_manager.ManagerTests.run_shell

    def assert_overseas_xray(self, path):
        dns = json.loads(path.read_text())
        self.assertEqual(dns['servers'], [
            'https+local://1.1.1.1/dns-query',
            'https+local://8.8.8.8/dns-query',
        ])
        self.assertNotIn('localhost', path.read_text())

    def test_new_xray_nodes_enable_and_reference_overseas_dns(self):
        self.run_shell('mkdir "$M_CONFIG/candidate"; m_build_config "$M_CONFIG/candidate"',
                       'https://panel.invalid\nfixture-key\ny\n1\n11,12\n1\nn\nn\n')
        stage = self.cfg / 'candidate'
        main = json.loads((stage / 'config.json').read_text())
        self.assertTrue(all(n.get('EnableDNS') for n in main['Nodes']))
        self.assertTrue(all(n['DNSType'] == 'ForceIPv4' for n in main['Nodes']))
        self.assertEqual(main['Cores'][0]['DnsConfigPath'], str(self.cfg / 'dns.json'))
        self.assert_overseas_xray(stage / 'dns.json')
        outbounds = json.loads((stage / 'custom_outbound.json').read_text())
        self.assertEqual(outbounds[0]['settings']['domainStrategy'], 'ForceIPv4v6')
        self.assertEqual(outbounds[1]['settings']['domainStrategy'], 'ForceIPv6')

    def test_other_templates_do_not_delegate_to_system_dns(self):
        self.run_shell('mkdir "$M_CONFIG/candidate"; check_ipv6_support() { printf 0; }; write_route_templates "$M_CONFIG/candidate"')
        origin = json.loads((self.cfg / 'candidate/sing_origin.json').read_text())
        self.assertEqual(origin['dns']['final'], 'cf')
        self.assertEqual(origin['dns']['servers'][0]['type'], 'https')
        self.assertEqual(origin['dns']['servers'][0]['server'], '1.1.1.1')
        self.assertEqual(origin['route']['default_domain_resolver']['server'], 'cf')
        hy2 = (self.cfg / 'candidate/hy2config.yaml').read_text()
        self.assertIn('resolver:\n  type: https\n  https:\n    addr: https://1.1.1.1/dns-query\n', hy2)
        self.assertNotIn('type: system', hy2)

    def test_legacy_xray_gets_separate_dns_core_for_new_batch(self):
        code = test_nodes.NodeTests.setup_nodes(self)
        old = json.loads(self.config.read_text())
        old['Cores'][0].pop('DnsConfigPath', None)
        self.config.write_text(json.dumps(old))
        existing_dns = self.cfg / 'dns.json'
        existing_dns.write_text('{"servers":["114.114.114.114","localhost"]}')
        originals = {p: p.read_bytes() for p in [self.config, self.out, self.route, existing_dns]}
        self.run_shell(code + 'm_edit',
                       '2\n0\nhttps://new.invalid\nfixture-new-key\ny\n1\n33,34\n1\nn\nn\ny\n')
        main = json.loads(self.config.read_text())
        self.assertEqual(main['Nodes'][:2], old['Nodes'])
        self.assertEqual(main['Cores'][:1], old['Cores'])
        core = main['Cores'][1]
        self.assertNotEqual(core['Name'], 'xray')
        self.assertTrue(all(n['Core'] == core['Name'] and n['EnableDNS'] for n in main['Nodes'][2:]))
        dns = self.cfg / core['DnsConfigPath']
        self.assertNotEqual(dns, existing_dns)
        self.assert_overseas_xray(dns)
        for path in [self.out, self.route, existing_dns]:
            self.assertEqual(path.read_bytes(), originals[path])

    def test_legacy_add_failure_removes_new_dns_and_restores_originals(self):
        code = test_nodes.NodeTests.setup_nodes(self)
        main = json.loads(self.config.read_text())
        main['Cores'][0].pop('DnsConfigPath', None)
        self.config.write_text(json.dumps(main))
        originals = {p: p.read_bytes() for p in self.cfg.iterdir() if p.is_file()}
        result = self.run_shell(code + 'm_health() { return 1; }; m_edit',
                                '2\n0\nhttps://new.invalid\nfixture-key\ny\n1\n33\n1\nn\nn\ny\n', check=False)
        self.assertNotEqual(result.returncode, 0)
        for path, content in originals.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual({p for p in self.cfg.iterdir() if p.is_file() and p.name != 'calls'}, set(originals))

    def test_new_hysteria_nodes_keep_existing_yaml_and_use_separate_resolver(self):
        code = test_nodes.NodeTests.setup_nodes(self)
        main = json.loads(self.config.read_text())
        main['Cores'].append({'Type': 'hysteria2'})
        self.config.write_text(json.dumps(main))
        previous_yaml = self.cfg / 'hy2config.yaml'
        previous_yaml.write_text('resolver:\n  type: system\n')
        self.run_shell(code + 'm_edit',
                       '2\n0\nhttps://new.invalid\nfixture-key\ny\n3\n51,52\n4\nnode.invalid\nn\ny\n')
        after = json.loads(self.config.read_text())
        paths = {n['Hysteria2ConfigPath'] for n in after['Nodes'][2:]}
        self.assertEqual(len(paths), 1)
        path = self.cfg / paths.pop()
        self.assertNotEqual(path, previous_yaml)
        self.assertIn('addr: https://1.1.1.1/dns-query', path.read_text())
        self.assertEqual(previous_yaml.read_text(), 'resolver:\n  type: system\n')

    def test_new_core_avoids_existing_names_files_and_symlinks(self):
        code = test_nodes.NodeTests.setup_nodes(self)
        main = json.loads(self.config.read_text())
        main['Cores'][0].pop('DnsConfigPath')
        main['Cores'].append({'Type': 'sing', 'Name': 'xray-dns'})
        self.config.write_text(json.dumps(main))
        collision = self.cfg / 'dns-xray-dns-2.json'
        collision.symlink_to(self.cfg / 'missing.json')
        self.run_shell(code + 'm_edit',
                       '2\n0\nhttps://new.invalid\nfixture-key\ny\n1\n33\n1\nn\nn\ny\n')
        after = json.loads(self.config.read_text())
        core = after['Cores'][-1]
        self.assertEqual(core['Name'], 'xray-dns-3')
        self.assertEqual(after['Nodes'][-1]['Core'], core['Name'])
        self.assert_overseas_xray(self.cfg / core['DnsConfigPath'])
        self.assertTrue(collision.is_symlink())
        self.assertFalse((self.cfg / 'missing.json').exists())

    def test_new_sing_core_does_not_reuse_orphaned_system_dns_file(self):
        code = test_nodes.NodeTests.setup_nodes(self)
        previous = '{"dns":{"servers":[{"type":"local","tag":"local"}]}}'
        self.origin.write_text(previous)
        self.run_shell(code + 'm_edit',
                       '2\n0\nhttps://new.invalid\nfixture-key\ny\n2\n33\n1\nn\nn\ny\n')
        core = json.loads(self.config.read_text())['Cores'][-1]
        self.assertNotEqual(core['OriginalPath'], str(self.origin))
        origin = json.loads((self.cfg / core['OriginalPath']).read_text())
        self.assertEqual(origin['dns']['servers'][0]['type'], 'https')
        self.assertEqual(self.origin.read_text(), previous)
