#!/bin/bash
set -euo pipefail
command -v python3 >/dev/null || { echo 'python3 is required' >&2; exit 127; }
command -v dirname >/dev/null || { echo 'dirname is required' >&2; exit 127; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B - "$ROOT/scripts/v1-v2-upgrade-state.py" <<'PY'
import importlib.util, json, os, pathlib, plistlib, tempfile, unittest
from unittest.mock import patch
import sys
path = pathlib.Path(sys.argv[1])
if not path.is_file():
    sys.exit('FAIL: checked upgrade state helper is missing')
spec = importlib.util.spec_from_file_location('upgrade_state', path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real_run = m.run

class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='family-foqos-v1-v2.', dir='/private/tmp')
        self.root = pathlib.Path(self.temp.name).resolve()
        self.home = self.root / 'home'
        self.udid = '00000000-0000-0000-0000-000000000001'
        device = self.home / 'Library/Developer/CoreSimulator/Devices' / self.udid / 'data/Containers'
        self.data = device / 'Data/Application/app'
        self.group = device / 'Shared/AppGroup/group'
        self.sibling = self.home / 'Library/Developer/CoreSimulator/Devices/other/data'
        self.sibling.mkdir(parents=True); (self.sibling / 'sentinel').write_text('keep')
        self.data.mkdir(parents=True); (self.data / 'sentinel').write_text('prior data')
        self.app = device / 'Bundle/Application/app'; self.app.mkdir(parents=True)
        (self.app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':m.BUNDLE,'CFBundleShortVersionString':'1.31.3','CFBundleVersion':'1'}))
        (self.group / 'Library/Application Support').mkdir(parents=True)
        self.store = self.group / 'Library/Application Support/default.store'
        self.store.write_text('prior store')
        self.dd = self.home / 'Library/Caches/ios-sim-gate/DerivedData/family-foqos/build2/session-collab'
        product = self.dd / 'Build/Products/Debug-iphonesimulator/FamilyFoqos.app'
        product.mkdir(parents=True)
        (product / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':m.BUNDLE,'CFBundleShortVersionString':'1.31.3','CFBundleVersion':'1'}))
        self.env = {'IOS_SIM_GATE_PROJECT':'family-foqos','IOS_SIM_GATE_AGENT':'build2','IOS_SIM_GATE_SESSION':'collab','IOS_SIM_GATE_UDID':self.udid,'IOS_SIM_GATE_DERIVED_DATA_PATH':str(self.dd),'IOS_SIM_GATE_DESTINATION':f'platform=iOS Simulator,id={self.udid}'}
        self.home_patch = patch.object(m.Path, 'home', return_value=self.home); self.home_patch.start()
        self.env_patch = patch.dict(os.environ, self.env); self.env_patch.start()
        # Only the external simulator boundary is replaced; backup/deletion use real files.
        self.run_patch = patch.object(m, 'run', side_effect=self.simctl); self.run_patch.start()
    def tearDown(self):
        self.run_patch.stop(); self.env_patch.stop(); self.home_patch.stop(); self.temp.cleanup()
    def simctl(self, *args, **kwargs):
        if args[0] == 'plutil': return json.dumps({m.BUNDLE:{}}).encode()
        op = args[2]
        if op == 'list': return json.dumps({'devices':{'iOS':[{'udid':self.udid,'state':'Booted','isAvailable':True}]}}).encode()
        if op == 'get_app_container': return str({'data':self.data,'app':self.app}.get(args[-1],self.group)).encode()
        return b''
    def invoke(self, action='prepare'):
        return m.entry([action, str(self.root)])
    def test_missing_gate_cannot_mutate(self):
        with patch.dict(os.environ, {'IOS_SIM_GATE_PROJECT':''}):
            with self.assertRaises(SystemExit): self.invoke()
        self.assertEqual(self.store.read_text(), 'prior store')
    def test_sibling_derived_data_cannot_mutate(self):
        with patch.dict(os.environ, {'IOS_SIM_GATE_DERIVED_DATA_PATH':str(self.dd.parent/'session-other')}):
            with self.assertRaises(SystemExit): self.invoke()
        self.assertEqual(self.store.read_text(), 'prior store')
    def test_container_escape_cannot_mutate(self):
        original = self.simctl
        def escape(*args, **kwargs):
            if args[0]=='xcrun' and args[2]=='get_app_container': return str(self.sibling).encode()
            return original(*args, **kwargs)
        with patch.object(m, 'run', side_effect=escape):
            with self.assertRaises(SystemExit): self.invoke()
        self.assertEqual((self.sibling/'sentinel').read_text(), 'keep')
        self.assertEqual(self.store.read_text(), 'prior store')
    def test_prepare_preserves_prior_state_and_sibling(self):
        self.invoke()
        self.assertEqual((self.root/'prior-app-group/Library/Application Support/default.store').read_text(), 'prior store')
        self.assertEqual((self.root/'prior-app-data/sentinel').read_text(), 'prior data')
        self.assertFalse(self.store.exists())
        self.assertEqual((self.sibling/'sentinel').read_text(), 'keep')
    def test_failed_child_status_is_exact(self):
        with patch.object(m.subprocess, 'run', return_value=m.subprocess.CompletedProcess([],42,b'',b'failed')):
            with self.assertRaises(SystemExit) as error: real_run('xcrun','simctl','list','devices','--json')
        self.assertEqual(error.exception.code, 42)
    def test_capture_rejects_missing_seed_without_creating_evidence(self):
        self.invoke()
        with self.assertRaises(SystemExit): self.invoke('capture-v1')
        self.assertFalse((self.root/'v1-app-data').exists())

unittest.main(argv=['upgrade-state-self-test'], verbosity=2)
PY
