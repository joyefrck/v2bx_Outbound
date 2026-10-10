"""SOCKS removal changes only the selected exit and uses the existing transaction."""
import json
import shutil
import unittest
from test_lightweight import Fixture
import test_lightweight


class DeleteSocksTests(Fixture):
    def configured(self, kind='xray', udp=False, two_nodes=False):
        self.setup_config(kind, two_nodes=two_nodes)
        self.original = self.contents(kind)
        endpoint = json.loads(self.endpoint.read_text())
        endpoint['udp'] = udp
        self.write(self.endpoint, endpoint)
        self.build()
        self.install_candidate(kind)
        self.tag = next(o['tag'] for o in self.generated()['out']
                        if o.get('protocol', o.get('type')) == 'socks')

    def contents(self, kind='xray'):
        paths = [self.out, self.route] if kind == 'xray' else [self.origin]
        return [json.loads(p.read_text()) for p in paths]

    def remove(self, index=0, check=True):
        return self.shell('build_remove_candidate %d' % index, check=check)

    def test_delete_restores_original_routing_for_both_cores_and_udp_modes(self):
        for kind in ('xray', 'sing'):
            for udp in (False, True):
                with self.subTest(kind=kind, udp=udp):
                    self.configured(kind, udp)
                    config_before = self.config.read_bytes()
                    self.remove()
                    self.install_candidate(kind)
                    self.assertEqual(self.contents(kind), self.original)
                    self.assertEqual(self.config.read_bytes(), config_before)

    def test_delete_keeps_second_node_exit_and_custom_rules(self):
        for kind in ('xray', 'sing'):
            with self.subTest(kind=kind):
                self.configured(kind, two_nodes=True)
                self.build(1)
                self.install_candidate(kind)
                custom = ({'domain': ['example.invalid'], 'outboundTag': 'direct', 'type': 'field'}
                          if kind == 'xray' else {'domain': ['example.invalid'], 'outbound': 'direct'})
                path = self.route if kind == 'xray' else self.origin
                data = json.loads(path.read_text())
                route = data if kind == 'xray' else data['route']
                route['rules'].insert(0, custom)
                self.write(path, data)
                before = self.contents(kind)
                second = next(o for o in (before[0] if kind == 'xray' else before[0]['outbounds'])
                              if o.get('protocol', o.get('type')) == 'socks' and o['tag'] != self.tag)
                self.remove()
                self.install_candidate(kind)
                result = self.generated()
                self.assertIn(second, result['out'])
                self.assertIn(custom, result['route']['rules'])
                self.assertNotIn(self.tag, json.dumps(result))

    def test_no_managed_exit_refused_without_writes(self):
        self.setup_config()
        before = self.contents()
        self.assertNotEqual(self.remove(check=False).returncode, 0)
        self.assertEqual(self.contents(), before)
        self.assertFalse((self.root / 'calls').exists())

    def test_missing_proxy_still_cleans_orphan_routes_and_udp_outbound(self):
        self.configured()
        self.write(self.out, [o for o in json.loads(self.out.read_text()) if o['tag'] != self.tag])
        self.remove()
        self.install_candidate()
        self.assertEqual(self.contents(), self.original)

    def test_shared_or_modified_node_route_is_refused(self):
        for modification in ({'inboundTag': ['another-node']}, {'domain': ['example.invalid']}):
            self.configured()
            route = json.loads(self.route.read_text())
            next(r for r in route['rules'] if r.get('outboundTag') == self.tag).update(modification)
            self.write(self.route, route)
            before = self.contents()
            self.assertNotEqual(self.remove(check=False).returncode, 0)
            self.assertEqual(self.contents(), before)

    def test_default_and_nested_outbound_references_are_refused(self):
        self.configured('sing')
        origin = json.loads(self.origin.read_text())
        origin['route']['final'] = self.tag
        self.write(self.origin, origin)
        self.assertNotEqual(self.remove(check=False).returncode, 0)
        del origin['route']['final']
        origin['outbounds'][0]['detour'] = self.tag
        self.write(self.origin, origin)
        self.assertNotEqual(self.remove(check=False).returncode, 0)

    def test_duplicate_or_changed_outbound_type_is_refused(self):
        self.configured()
        outs = json.loads(self.out.read_text())
        proxy = next(o for o in outs if o['tag'] == self.tag)
        outs.append(dict(proxy))
        self.write(self.out, outs)
        self.assertNotEqual(self.remove(check=False).returncode, 0)
        outs.pop()
        proxy['protocol'] = 'freedom'
        self.write(self.out, outs)
        self.assertNotEqual(self.remove(check=False).returncode, 0)

    def test_delete_can_be_applied_and_restored_with_original_permissions(self):
        self.configured()
        self.out.chmod(0o640)
        before = self.out.read_bytes(), self.route.read_bytes()
        self.shell(test_lightweight.TransactionTests.MOCKS + '''
build_remove_candidate 0 || exit 2
apply_candidate remove || exit 3
backup_list; TX_DIR=${BACKUPS[0]}
restore_check false && restore_files
''')
        self.assertEqual((self.out.read_bytes(), self.route.read_bytes()), before)
        self.assertEqual(self.out.stat().st_mode & 0o777, 0o640)

    def test_failed_delete_start_rolls_back(self):
        self.configured()
        before = self.out.read_bytes(), self.route.read_bytes()
        result = self.shell(test_lightweight.TransactionTests.MOCKS + '''
build_remove_candidate 0 || exit 2
service_start_check() { return 1; }
apply_candidate remove
''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.out.read_bytes(), self.route.read_bytes()), before)

    def test_delete_drift_does_not_stop_service(self):
        self.configured()
        result = self.shell(test_lightweight.TransactionTests.MOCKS + '''
build_remove_candidate 0 || exit 2
printf '\\n' >> "${FILES[0]}"
apply_candidate remove
''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'calls').exists())

    def test_delete_menu_does_not_probe_or_require_healthy_service(self):
        self.configured()
        result = self.shell('''
ask() { REPLY=1; }
confirm() { return 0; }
healthy() { echo unexpected-health-check; return 1; }
probe_socks() { echo unexpected-probe; return 1; }
submit_job() { echo "SUBMITTED:$1"; }
remove_menu
''')
        self.assertIn('SUBMITTED:remove', result.stdout)
        self.assertNotIn('unexpected-', result.stdout)

    def test_cancel_delete_does_not_write_or_dispatch(self):
        self.configured()
        before = self.contents()
        result = self.shell('''
ask() { REPLY=1; }
confirm() { return 1; }
submit_job() { echo unexpected-dispatch; return 1; }
remove_menu
''')
        self.assertEqual(before, self.contents())
        self.assertNotIn('unexpected-dispatch', result.stdout)

    def test_failed_delete_dispatch_leaves_saved_exit_untouched(self):
        self.configured()
        before = self.contents()
        result = self.shell('''
SELF_PATH=$1
build_remove_candidate 0 || exit 2
systemd-run() { return 1; }
submit_job remove
''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.contents(), before)
        job = next((self.root / 'socks-helper-jobs').glob('job-*'))
        self.assertEqual(json.loads((job / 'job.json').read_text())['action'], 'remove')
        self.assertEqual(json.loads((job / 'result.json').read_text())['status'], 'failed')
        self.assertFalse((job / 'v2bx-socks.work').exists())
        self.assertFalse((self.root / 'calls').exists())

    @unittest.skipUnless(shutil.which('flock'), 'Linux worker lock verified on Linux')
    def test_delete_worker_recovers_without_preexisting_healthy_service(self):
        self.configured()
        self.shell(test_lightweight.TransactionTests.MOCKS + '''
SELF_PATH=$1
healthy() { echo unexpected-health-check; return 1; }
discover() { return 0; }
build_remove_candidate 0 || exit 2
prepare_job remove || exit 3
job_worker "$JOB_DIR"
''')
        self.assertEqual(self.contents(), self.original)
        job = next((self.root / 'socks-helper-jobs').glob('job-*'))
        self.assertEqual(json.loads((job / 'result.json').read_text())['status'], 'succeeded')
        self.assertNotIn('unexpected-health-check', (job / 'output.log').read_text())
        self.assertFalse((job / 'v2bx-socks.work').exists())
