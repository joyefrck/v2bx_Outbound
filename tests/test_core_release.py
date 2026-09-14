"""Trust, archive and transaction boundaries; downloads are local fixtures only."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile
import test_manager


def digest(data): return hashlib.sha256(data).hexdigest()

class CoreReleaseTests(unittest.TestCase):
    setUp = test_manager.ManagerTests.setUp
    run_shell = test_manager.ManagerTests.run_shell

    def release(self, entries=None, platform='linux-amd64', actual_version='v1.0.0'):
        subprocess.run(['openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:2048','-out',str(self.root/'key')],check=True,capture_output=True)
        subprocess.run(['openssl','pkey','-in',str(self.root/'key'),'-pubout','-out',str(self.root/'public')],check=True,capture_output=True)
        self.info={'schema':1,'source_state':'commit','version':actual_version,'source_revision':'a'*40,'patch_index_sha256':'b'*64,'os':'linux','arch':'amd64','cores':['hysteria2','sing','xray'],'modules':{n:{'path':n,'version':'v1'} for n in ['xray','sing-box','hysteria2','hysteria2-extras']}}
        binary=('#!/bin/sh\ncat <<\'JSON\'\n'+json.dumps(self.info)+'\nJSON\n').encode()
        files={'V2bX':binary,'build-info.json':json.dumps(self.info).encode(),'cores.lock.json':b'{}','geoip.dat':b'geoip','geosite.dat':b'geosite'}
        with zipfile.ZipFile(self.root/'core.zip','w') as z:
            for name,content in files.items():z.writestr(name,content)
            for name,content in entries or []:z.writestr(name,content)
        self.manifest={'schema':1,'source_state':'commit','tag':'core-v1.0.0','version':'v1.0.0','platform':platform,'source_revision':'a'*40,'patch_index_sha256':'b'*64,'asset':'V2bX-linux-amd64.zip','sha256':digest((self.root/'core.zip').read_bytes()),'cores':self.info['modules'],'files':{k:digest(v) for k,v in files.items()}}
        self.sign()
        return '''
fixture=${M_CONFIG%/*}
m_arch() { echo amd64; }
m_core_public_key() { cat "$fixture/public"; }
m_core_release() { echo '{"tag_name":"core-v1.0.0"}' > "$1"; }
m_fetch() {
 case $1 in
  https://github.com/joyefrck/v2bx_Outbound/releases/download/core-v1.0.0/manifest-linux-amd64.json) cp "$fixture/manifest.json" "$2";;
  https://github.com/joyefrck/v2bx_Outbound/releases/download/core-v1.0.0/manifest-linux-amd64.json.sig) cp "$fixture/manifest.sig" "$2";;
  https://github.com/joyefrck/v2bx_Outbound/releases/download/core-v1.0.0/V2bX-linux-amd64.zip) cp "$fixture/core.zip" "$2";;
  *) echo unexpected-source >&2; return 97;;
 esac
}
mkdir "$fixture/stage"
m_prepare_core "$fixture/stage"
'''

    def sign(self):
        (self.root/'manifest.json').write_text(json.dumps(self.manifest))
        subprocess.run(['openssl','dgst','-sha256','-sign',str(self.root/'key'),'-out',str(self.root/'manifest.sig'),str(self.root/'manifest.json')],check=True,capture_output=True)

    def test_valid_signed_bundle_has_measured_core_info(self):
        self.run_shell(self.release())
        self.assertTrue((self.root/'stage/new/core-manifest.sig').exists())

    def test_bad_signature_never_extracts(self):
        script=self.release();(self.root/'manifest.json').write_text('{}')
        r=self.run_shell(script,check=False);self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.root/'stage/new').exists());self.assertIn('签名',r.stderr)

    def test_bad_package_checksum_never_extracts(self):
        script=self.release();(self.root/'core.zip').write_bytes(b'corrupt')
        self.assertNotEqual(self.run_shell(script,check=False).returncode,0)
        self.assertFalse((self.root/'stage/new').exists())

    def test_traversal_in_signed_archive_is_rejected(self):
        r=self.run_shell(self.release([('../outside',b'no')]),check=False)
        self.assertNotEqual(r.returncode,0);self.assertFalse((self.root/'outside').exists())

    def test_duplicate_archive_entry_is_rejected(self):
        self.assertNotEqual(self.run_shell(self.release([('V2bX',b'no')]),check=False).returncode,0)

    def test_wrong_platform_is_rejected(self):
        self.assertNotEqual(self.run_shell(self.release(platform='linux-arm64'),check=False).returncode,0)

    def test_working_tree_build_is_never_installable(self):
        script=self.release()
        self.manifest['source_state']='working-tree'
        self.sign()
        self.assertNotEqual(self.run_shell(script,check=False).returncode,0)
        self.assertFalse((self.root/'stage/new').exists())

    def test_signed_symlink_is_rejected(self):
        script=self.release()
        archive=self.root/'core.zip'
        with zipfile.ZipFile(archive) as z:
            entries={n:z.read(n) for n in z.namelist() if n!='V2bX'}
        with zipfile.ZipFile(archive,'w') as z:
            link=zipfile.ZipInfo('V2bX');link.create_system=3
            link.external_attr=0o120777 << 16
            z.writestr(link,'/tmp/v2bx-unexpected-target')
            for name,data in entries.items():z.writestr(name,data)
        self.manifest['sha256']=digest(archive.read_bytes());self.sign()
        self.assertNotEqual(self.run_shell(script,check=False).returncode,0)

    def test_compiled_version_must_match_signed_manifest(self):
        r=self.run_shell(self.release(actual_version='v0.4.0'),check=False)
        self.assertNotEqual(r.returncode,0);self.assertIn('实际编译内核',r.stderr)

    def test_no_validated_release_does_not_use_old_source(self):
        r=self.run_shell('''
m_fetch() { [[ $1 == 'https://api.github.com/repos/joyefrck/v2bx_Outbound/releases?per_page=100' ]] || exit 97; echo '[{"tag_name":"core-v9.0.0","draft":false,"prerelease":true},{"tag_name":"v0.4.0","draft":false,"prerelease":false}]' > "$2"; }
m_core_release "$M_CONFIG/release.json"
''',check=False)
        self.assertNotEqual(r.returncode,0);self.assertIn('尚无经过验证',r.stderr)

    def test_latest_stable_filters_candidates_and_unrelated_releases(self):
        self.run_shell('''
m_fetch() { echo '[{"tag_name":"core-v9.0.0","draft":false,"prerelease":true,"published_at":"2026-09-14"},{"tag_name":"tools-v9.0.0","draft":false,"prerelease":false,"published_at":"2026-09-14"},{"tag_name":"core-v1.0.0","draft":false,"prerelease":false,"published_at":"2026-09-13"}]' > "$2"; }
m_core_release "$M_CONFIG/release.json" && [[ $(jq -r .tag_name "$M_CONFIG/release.json") == core-v1.0.0 ]]
''')

class CoreTransactionTests(unittest.TestCase):
    setUp=test_manager.ManagerTests.setUp
    run_shell=test_manager.ManagerTests.run_shell
    mock_core=test_manager.ManagerTests.mock_core

    def test_failed_preflight_never_stops_service(self):
        r=self.run_shell(self.mock_core()+'''m_core_preflight() { return 1; }; systemctl() { echo "$1" >> "$M_CONFIG/calls"; }; m_install_core''',check=False)
        self.assertNotEqual(r.returncode,0);self.assertFalse((self.cfg/'calls').exists())
        self.assertIn('old',(self.binary/'V2bX').read_text())

    def test_manual_rollback_preserves_stopped_state_and_current_configuration(self):
        script=self.mock_core()+'''
systemctl() { [[ $1 != is-active ]] || return 1; echo "$1" >> "$M_CONFIG/calls"; }
m_install_core || exit 1
printf changed > "$M_CONFIG/config.json"
m_core_rollback
'''
        self.run_shell(script)
        self.assertIn('old',(self.binary/'V2bX').read_text())
        self.assertEqual((self.cfg/'config.json').read_text(),'changed')
        self.assertNotIn('start',(self.cfg/'calls').read_text())

    def test_tampered_backup_is_not_installed(self):
        r=self.run_shell(self.mock_core()+'''
systemctl() { [[ $1 != is-active ]]; }
m_install_core || exit 1
backup=$(cat "$M_CONFIG/last-core-backup")
printf tampered > "$backup/binary/V2bX"
m_core_rollback
''',check=False)
        self.assertNotEqual(r.returncode,0);self.assertIn('new',(self.binary/'V2bX').read_text())

    def test_rollback_stop_failure_keeps_current_binary(self):
        r=self.run_shell(self.mock_core()+'''
systemctl() { [[ $1 != is-active ]]; }
m_install_core || exit 1
systemctl() { [[ $1 != stop ]]; }
m_health() { return 0; }
m_core_rollback
''',check=False)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('new',(self.binary/'V2bX').read_text())
