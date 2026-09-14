"""Actual transient systemd workers; only their V2bX service boundary is simulated."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(sys.platform=='linux' and os.geteuid()==0 and os.environ.get('V2BX_SYSTEMD_TEST')=='1' and Path('/run/systemd/system').is_dir(), 'requires explicitly enabled disposable systemd test environment')
class CoreSystemdJobs(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='v2bx-core-systemd-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.config=self.root/'config';self.config.mkdir();self.binary=self.root/'binary';self.binary.mkdir()
        (self.config/'config.json').write_text('{}')
        (self.root/'unit').write_text('fixture-unit')
        (self.binary/'V2bX').write_text('#!/bin/sh\necho "V2bX v0.4.0"\n');(self.binary/'V2bX').chmod(0o755)
        for f in ['geoip.dat','geosite.dat']:(self.config/f).write_text('custom-geo')
        (self.config/'state').write_text('active')
        self.wrapper=self.root/'manager.sh'
        self.wrapper.write_text('source '+str(ROOT/'v2bx-manager.sh')+'\nM_CONFIG='+str(self.config)+'\nM_BINARY='+str(self.binary)+'\nM_UNIT='+str(self.root/'unit')+'\nM_SELF='+str(self.wrapper)+'\nM_HELPER='+str(ROOT/'v2bx-socks.sh')+'''
m_platform() { :; }; m_dependencies() { :; }; m_standard_config() { :; }
systemctl() {
 if [[ ${2:-} == V2bX || ${3:-} == V2bX ]]; then
  echo "$1" >> "$M_CONFIG/calls"
  case $1 in
   is-active) [[ $(cat "$M_CONFIG/state") == active ]];;
   start) echo active > "$M_CONFIG/state";;
   stop) echo inactive > "$M_CONFIG/state";;
   *) return 0;;
  esac
 else command systemctl "$@"; fi
}
m_health() { [[ ! -f $M_CONFIG/fail-health || $(m_core_version "$M_BINARY/V2bX") == v0.4.0 ]]; }
m_core_preflight() { [[ ! -f $M_CONFIG/fail-preflight ]]; }
m_prepare_core() {
 sleep 2
 mkdir "$1/new"
 printf '#!/bin/sh\\necho "V2bX v1.0.0"\\n' > "$1/new/V2bX"
 chmod 755 "$1/new/V2bX"
 echo upstream-geo > "$1/new/geoip.dat";echo upstream-geo > "$1/new/geosite.dat"
}
case ${1:-} in
 __submit-hangup) m_core_job_submit update && sleep 30;;
 *) m_main "$@";;
esac
''')

    def wait_result(self, previous=None):
        for _ in range(150):
            latest=self.config/'last-core-job'
            if latest.exists():
                job=Path(latest.read_text().strip())
                if job!=previous and (job/'result.json').exists():
                    return job,json.loads((job/'result.json').read_text()),(job/'output.log').read_text()
            time.sleep(.1)
        self.fail('worker did not complete')

    def test_ssh_hangup_does_not_cancel_update_and_manual_rollback_works(self):
        proc=subprocess.Popen(['bash',str(self.wrapper),'__submit-hangup'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                if (self.config/'last-core-job').exists():break
                time.sleep(.05)
            proc.send_signal(signal.SIGHUP);proc.wait(timeout=5)
            job,result,output=self.wait_result()
            self.assertEqual(result['status'],'succeeded',output)
            self.assertIn('v1.0.0',(self.binary/'V2bX').read_text())
            self.assertEqual((self.config/'geoip.dat').read_text(),'custom-geo')
            subprocess.run(['bash',str(self.wrapper),'core-rollback'],check=True,capture_output=True,text=True)
            _,result,output=self.wait_result(previous=job)
            self.assertEqual(result['status'],'succeeded',output)
            self.assertIn('v0.4.0',(self.binary/'V2bX').read_text())
        finally:
            if proc.poll() is None:proc.kill();proc.wait()

    def test_new_runtime_health_failure_restores_old_runtime(self):
        (self.config/'fail-health').touch()
        subprocess.run(['bash',str(self.wrapper),'update'],check=True,capture_output=True,text=True)
        _,result,output=self.wait_result()
        self.assertEqual(result['status'],'failed',output)
        self.assertIn('v0.4.0',(self.binary/'V2bX').read_text())
        self.assertEqual((self.config/'state').read_text().strip(),'active')
        self.assertIn('已回滚',output)

    def test_preflight_failure_does_not_stop_service(self):
        (self.config/'fail-preflight').touch()
        subprocess.run(['bash',str(self.wrapper),'update'],check=True,capture_output=True,text=True)
        _,result,output=self.wait_result()
        self.assertEqual(result['status'],'failed',output)
        self.assertNotIn('stop',(self.config/'calls').read_text() if (self.config/'calls').exists() else '')
