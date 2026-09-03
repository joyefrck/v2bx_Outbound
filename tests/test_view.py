"""Read-only display tests: use fixture configs and assert credentials stay hidden."""
import json
from test_lightweight import ENDPOINT, Fixture


class ViewTests(Fixture):
    def view(self):
        paths = [p for p in (self.config, self.out, self.route, self.origin) if p.exists()]
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in paths}
        result = self.shell('''
service_stop() { exit 71; }
service_start_check() { exit 72; }
probe_socks() { exit 73; }
TASK_DIR=''
show_socks_config
''')
        self.assertEqual(before, {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in paths})
        self.assertNotIn(ENDPOINT['password'], result.stdout + result.stderr)
        self.assertNotIn('fixture-only', result.stdout + result.stderr)
        return result.stdout

    def test_xray_shows_configured_node_and_separate_unconfigured_node(self):
        self.setup_config(two_nodes=True)
        self.build()
        self.install_candidate()
        text = self.view()
        first, second = text.split('节点 ID 12')
        self.assertIn('节点 ID 11', first)
        self.assertIn('SOCKS 地址：127.0.0.1', first)
        self.assertIn('端口：1080', first)
        self.assertIn('用户名：test:user', first)
        self.assertIn('密码：******', first)
        self.assertIn('UDP：阻断', first)
        self.assertIn('路由：已找到节点专用规则', first)
        self.assertIn('未找到本助手为此节点配置的 SOCKS 出口', second)
        self.assertNotIn('用户名：test:user', second)

    def test_sing_shows_saved_outbound_and_udp_setting(self):
        self.setup_config('sing')
        self.write(self.endpoint, dict(ENDPOINT, udp=True))
        self.build()
        self.install_candidate('sing')
        text = self.view()
        self.assertIn('SOCKS 地址：127.0.0.1', text)
        self.assertIn('UDP：允许', text)
        self.assertIn('密码：******', text)

    def test_sing_tcp_only(self):
        self.setup_config('sing')
        self.build()
        self.install_candidate('sing')
        self.assertIn('UDP：阻断', self.view())

    def test_no_authentication(self):
        self.setup_config()
        self.write(self.endpoint, dict(ENDPOINT, username='', password='', udp=True))
        self.build()
        self.install_candidate()
        text = self.view()
        self.assertIn('认证：无账号 / IP 白名单', text)
        self.assertIn('UDP：允许', text)

    def test_unconfigured_node_is_not_claimed_to_be_direct(self):
        self.setup_config()
        text = self.view()
        self.assertIn('未找到本助手为此节点配置的 SOCKS 出口', text)
        self.assertNotIn('正在直连', text)

    def test_missing_node_rule_is_reported_while_endpoint_remains_visible(self):
        self.setup_config()
        self.build()
        self.install_candidate()
        self.write(self.route, {'rules': []})
        text = self.view()
        self.assertIn('SOCKS 地址：127.0.0.1', text)
        self.assertIn('路由：未找到标准节点规则', text)
        self.assertIn('UDP：无法确认', text)

    def test_named_node_and_relative_paths(self):
        self.setup_config()
        config = json.loads(self.config.read_text())
        config['Nodes'][0]['Name'] = 'named-node'
        config['Cores'][0]['Name'] = 'core-one'
        config['Nodes'][0]['Core'] = 'core-one'
        config['Cores'][0]['OutboundConfigPath'] = 'out.json'
        config['Cores'][0]['RouteConfigPath'] = 'route.json'
        self.write(self.config, config)
        self.build()
        self.install_candidate()
        self.assertIn('SOCKS 地址：127.0.0.1', self.view())

    def test_invalid_or_missing_file_is_reported_without_dumping_contents(self):
        self.setup_config()
        self.route.write_text('{"password":"do-not-display", BROKEN')
        text = self.view()
        self.assertIn('无法读取', text)
        self.assertNotIn('do-not-display', text)
        self.route.unlink()
        self.assertIn('无法读取', self.view())

    def test_unsupported_core_is_reported(self):
        self.setup_config()
        config = json.loads(self.config.read_text())
        config['Nodes'][0]['Core'] = 'hysteria2'
        config['Cores'] = [{'Type': 'hysteria2'}]
        self.write(self.config, config)
        self.assertIn('暂不支持查看此内核', self.view())
