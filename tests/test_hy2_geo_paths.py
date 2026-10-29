"""HY2 must use installed Geo assets even when generated in a temporary stage."""
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import unittest

import test_manager
import test_nodes


class Hy2GeoPathsTests(unittest.TestCase):
    setUp = test_manager.ManagerTests.setUp
    run_shell = test_manager.ManagerTests.run_shell

    def geo_paths(self, path):
        values = {}
        in_acl = False
        for line in path.read_text().splitlines():
            if line == 'acl:':
                in_acl = True
            elif in_acl and line and not line.startswith(' '):
                break
            elif in_acl and line.startswith(('  geoip:', '  geosite:')):
                key, value = line.strip().split(':', 1)
                values[key] = Path(json.loads(value.strip()))
        self.assertEqual(set(values), {'geoip', 'geosite'})
        return values

    def assert_geo_paths(self, yaml_path, root):
        self.assertEqual(self.geo_paths(yaml_path), {
            'geoip': root / 'geoip.dat',
            'geosite': root / 'geosite.dat',
        })
        acl = yaml_path.read_text().split('  inline:\n', 1)[1].split('masquerade:', 1)[0]
        self.assertEqual(acl, '    - direct(geosite:google)\n'
                             '    - reject(geosite:cn)\n'
                             '    - reject(geoip:cn)\n')

    def test_staged_generation_references_final_assets_after_stage_removal(self):
        for name in ['geoip.dat', 'geosite.dat']:
            (self.cfg / name).write_bytes(b'installed-geo-fixture')
            (self.binary / name).write_bytes(b'different-working-directory-fixture')
        self.run_shell('mkdir "$M_CONFIG/candidate"; m_build_config "$M_CONFIG/candidate"',
                       'https://panel.invalid\nfixture-key\ny\n3\n11,12\n4\nnode.invalid\nn\n')
        stage = self.cfg / 'candidate'
        main = json.loads((stage / 'config.json').read_text())
        installed = self.cfg / 'hy2config.yaml'
        self.assertTrue(all(n['Hysteria2ConfigPath'] == str(installed) for n in main['Nodes']))
        self.assert_geo_paths(stage / 'hy2config.yaml', self.cfg)
        shutil.copyfile(stage / 'hy2config.yaml', installed)
        shutil.rmtree(stage)
        for path in self.geo_paths(installed).values():
            self.assertEqual(path.read_bytes(), b'installed-geo-fixture')

    def test_template_only_call_uses_supplied_target(self):
        target = self.cfg / 'standalone'
        target.mkdir()
        result = subprocess.run(['bash', '-uc', '''
source "$1/src/manager/templates.sh"
check_ipv6_support() { printf 0; }
write_route_templates "$2"
''', 'hy2-template', str(test_manager.ROOT), str(target)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_geo_paths(target / 'hy2config.yaml', target)

    def test_final_asset_paths_are_yaml_escaped(self):
        final_root = self.root / 'installed geo #"quoted"\\path'
        self.run_shell('mkdir "$M_CONFIG/candidate"; target="$M_CONFIG/candidate"; '
                       'M_CONFIG=' + shlex.quote(str(final_root)) + '; '
                       'check_ipv6_support() { printf 0; }; write_route_templates "$target"')
        self.assert_geo_paths(self.cfg / 'candidate/hy2config.yaml', final_root)

    def test_appending_hy2_nodes_uses_shared_assets_and_preserves_old_yaml(self):
        code = test_nodes.NodeTests.setup_nodes(self)
        original = json.loads(self.config.read_text())
        original['Cores'].append({'Type': 'hysteria2'})
        self.config.write_text(json.dumps(original))
        old_yaml = self.cfg / 'hy2config.yaml'
        old_yaml.write_text('acl:\n  geoip: /custom/geoip.dat\n  geosite: /custom/geosite.dat\n')
        old_bytes = old_yaml.read_bytes()
        self.run_shell(code + 'm_edit',
                       '2\n0\nhttps://new.invalid\nfixture-key\ny\n3\n51,52\n4\nnode.invalid\nn\ny\n')
        after = json.loads(self.config.read_text())
        self.assertEqual(after['Nodes'][:2], original['Nodes'])
        self.assertEqual(after['Cores'], original['Cores'])
        paths = {n['Hysteria2ConfigPath'] for n in after['Nodes'][2:]}
        self.assertEqual(len(paths), 1)
        new_yaml = Path(paths.pop())
        self.assertNotEqual(new_yaml, old_yaml)
        self.assert_geo_paths(new_yaml, self.cfg)
        self.assertEqual(old_yaml.read_bytes(), old_bytes)
