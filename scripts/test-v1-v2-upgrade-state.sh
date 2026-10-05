#!/bin/bash
set -euo pipefail
command -v python3 >/dev/null || { echo 'python3 is required' >&2; exit 127; }
command -v dirname >/dev/null || { echo 'dirname is required' >&2; exit 127; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B - "$ROOT/scripts/v1-v2-upgrade-state.py" <<'PY'
import importlib.util, io, json, os, pathlib, plistlib, shutil, tempfile, unittest
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
        self.product = product
        self.calls = []
        self.env = {'IOS_SIM_GATE_PROJECT':'family-foqos','IOS_SIM_GATE_RUNTIME_VERSION':'26.5','IOS_SIM_GATE_AGENT':'build2','IOS_SIM_GATE_SESSION':'collab','IOS_SIM_GATE_UDID':self.udid,'IOS_SIM_GATE_DERIVED_DATA_PATH':str(self.dd),'IOS_SIM_GATE_DESTINATION':f'platform=iOS Simulator,id={self.udid}'}
        self.home_patch = patch.object(m.Path, 'home', return_value=self.home); self.home_patch.start()
        self.env_patch = patch.dict(os.environ, self.env); self.env_patch.start()
        # Only the external simulator boundary is replaced; backup/deletion use real files.
        self.run_patch = patch.object(m, 'run', side_effect=self.simctl); self.run_patch.start()
    def tearDown(self):
        self.run_patch.stop(); self.env_patch.stop(); self.home_patch.stop(); self.temp.cleanup()
    def simctl(self, *args, **kwargs):
        self.calls.append(args)
        if args[0] == 'plutil': return json.dumps({m.BUNDLE:{}}).encode()
        op = args[2]
        if op == 'list': return json.dumps({'devices':{'iOS':[{'udid':self.udid,'state':'Booted','isAvailable':True}]}}).encode()
        if op == 'get_app_container': return str({'data':self.data,'app':self.app}.get(args[-1],self.group)).encode()
        return b''
    def invoke(self, action='prepare'):
        args = [action, str(self.root)]
        if action == 'prepare': args += ['--persona', 'manual', '--v1-app', str(self.product)]
        return m.entry(args)
    def seeded(self, *, capture=True):
        self.invoke()
        self.store.write_text('V1 synthetic store')
        docs = self.data / 'Documents'; docs.mkdir(exist_ok=True)
        (docs/'rc-v1-seed.json').write_text(json.dumps({'persona':'manual','store':str(self.store),'profiles':[{'id':'profile','name':'RC Manual'}],'sessionID':None}))
        prefs = self.group/'Library/Preferences'; prefs.mkdir(parents=True, exist_ok=True)
        (prefs/f'{m.GROUP}.plist').write_bytes(plistlib.dumps({'profileSnapshots':json.dumps({'profile':{'id':'profile'}}).encode()}))
        if capture: self.invoke('capture-v1')
    def test_wrong_product_fails_before_simulator_change(self):
        (self.product/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'other','CFBundleShortVersionString':'1.31.3','CFBundleVersion':'1'}))
        self.rejected(self.invoke, "unexpected application/runner bundle identifier")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.store.read_text(), 'prior store')
    def test_wrong_owner_fails_before_simulator_change(self):
        self.seeded(); self.calls.clear()
        with patch.dict(os.environ, {'IOS_SIM_GATE_UDID':'00000000-0000-0000-0000-000000000002','IOS_SIM_GATE_DESTINATION':'platform=iOS Simulator,id=00000000-0000-0000-0000-000000000002'}):
            self.rejected(lambda: self.invoke('capture-v1'), 'evidence belongs to another gate owner')
        self.assertEqual(self.calls, [])
    def test_inactive_v1_capture_is_accepted(self):
        self.seeded()
        self.assertTrue((self.root/'v1-app-group/Library/Application Support/default.store').is_file())
    def test_install_over_never_uninstalls_or_clears(self):
        self.seeded(); self.calls.clear()
        v2 = self.root/'candidate.app'; v2.mkdir()
        (v2/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':m.BUNDLE,'CFBundleShortVersionString':'2.0.79','CFBundleVersion':'97'}))
        m.entry(['install-v2',str(self.root),'--v2-app',str(v2),'--source-revision','a'*40])
        self.assertFalse(any(c[2]=='uninstall' for c in self.calls if c[0]=='xcrun'))
        self.assertEqual(self.store.read_text(),'V1 synthetic store')
    def test_failed_install_retains_baseline_and_exact_status(self):
        self.seeded()
        v2 = self.root/'candidate.app'; v2.mkdir()
        (v2/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':m.BUNDLE,'CFBundleShortVersionString':'2.0.79','CFBundleVersion':'97'}))
        original = self.simctl
        def fail_install(*args, **kwargs):
            if args[0]=='xcrun' and args[2]=='install': raise SystemExit(42)
            return original(*args, **kwargs)
        with patch.object(m,'run',side_effect=fail_install):
            with self.assertRaises(SystemExit) as error: m.entry(['install-v2',str(self.root),'--v2-app',str(v2),'--source-revision','a'*40])
        self.assertEqual(error.exception.code,42)
        self.assertTrue((self.root/'v1-app-group/Library/Application Support/default.store').is_file())
        self.assertFalse((self.root/'v2-installed.json').exists())
    def test_missing_phase_fails_before_simulator_change(self):
        self.seeded(); self.calls.clear()
        self.rejected(lambda: self.invoke('capture-v2'), 'missing required persona, product, phase or generation')
        self.assertEqual(self.calls, [])
    def test_sibling_product_fails_before_simulator_change(self):
        sibling = self.dd.parent/'session-other/FamilyFoqos.app'
        sibling.mkdir(parents=True)
        (sibling/'Info.plist').write_bytes((self.product/'Info.plist').read_bytes())
        self.rejected(lambda: m.entry(['prepare',str(self.root),'--persona','manual','--v1-app',str(sibling)]), "refusing another owner's build product")
        self.assertEqual(self.calls, [])
    def v2(self):
        self.seeded()
        candidate = self.root/'candidate.app'; candidate.mkdir()
        info = {'CFBundleIdentifier':m.BUNDLE,'CFBundleShortVersionString':'2.0.79','CFBundleVersion':'97'}
        (candidate/'Info.plist').write_bytes(plistlib.dumps(info))
        m.entry(['install-v2',str(self.root),'--v2-app',str(candidate),'--source-revision','a'*40])
        (self.app/'Info.plist').write_bytes(plistlib.dumps(info))
        return self.data/'Documents/upgrade-report.json'
    def test_stale_report_cannot_capture_or_mutate(self):
        report = self.v2()
        report.write_text(json.dumps({'phase':'journey','generation':self.udid,'persona':'manual','build':'97','version':'2.0.79','source':'a'*40,'count':1}))
        self.calls.clear()
        self.rejected(lambda: m.entry(['capture-v2',str(self.root),'--report-count','1','--phase','first-launch','--generation',self.udid]), 'missing/stale/wrong-phase diagnostic report')
        self.assertFalse(any(c[2] in ('shutdown','uninstall','install') for c in self.calls if c[0]=='xcrun'))
        self.assertFalse((self.root/'v2-first-launch-installed.json').exists())
        self.assertTrue((self.root/'v1-app-group/Library/Application Support/default.store').is_file())
    def test_fresh_phase_kept_separately_with_v1_sentinel(self):
        report = self.v2()
        report.write_text(json.dumps({'phase':'first-launch','generation':self.udid,'persona':'manual','build':'97','version':'2.0.79','source':'a'*40,'count':1}))
        m.entry(['capture-v2',str(self.root),'--report-count','1','--phase','first-launch','--generation',self.udid])
        self.assertTrue((self.root/'v2-first-launch-report.json').is_file())
        self.assertTrue((self.root/'v1-app-group/Library/Application Support/default.store').is_file())
    def test_changed_sentinel_cannot_claim_upgrade(self):
        report=self.v2()
        report.write_text(json.dumps({'phase':'first-launch','generation':self.udid,'persona':'manual','build':'97','version':'2.0.79','source':'a'*40,'count':1}))
        m.entry(['verify-run',str(self.root),'--phase','first-launch'])
        seed_path=self.data/'Documents/rc-v1-seed.json'
        seed=json.loads(seed_path.read_text()); seed['profiles'][0]['name']='Changed sentinel'
        seed_path.write_text(json.dumps(seed))
        self.rejected(lambda: m.entry(['capture-v2',str(self.root),'--report-count','1','--phase','first-launch','--generation',self.udid]), 'V1 sentinel changed during install-over')
        self.assertFalse((self.root/'v2-first-launch-installed.json').exists())
    def test_xctestrun_only_installs_pinned_phase_products(self):
        source=self.root/'generated.xctestrun'
        target={'BlueprintName':'FoqosUITests','IsUITestBundle':True,'TestHostPath':'old','TestBundlePath':'old','UITargetAppPath':'old'}
        source.write_bytes(plistlib.dumps({'TestConfigurations':[{'TestTargets':[target]}]}))
        destination=self.root/'ui.xctestrun'
        m.pin_xctestrun(source,destination,{'bundle':'discovered.runner.xctrunner'},self.root/'runner.app',self.root/'v1.app')
        actual=plistlib.loads(destination.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
        self.assertEqual(actual['TestHostBundleIdentifier'],'discovered.runner.xctrunner')
        self.assertFalse(actual.get('UseDestinationArtifacts',False))
        self.assertEqual(actual['TestHostPath'],str(self.root/'runner.app'))
        self.assertEqual(actual['TestBundlePath'],str(self.root/'runner.app/PlugIns/FoqosUITests.xctest'))
        self.assertEqual(actual['UITargetAppPath'],str(self.root/'v1.app'))
        self.assertEqual(set(actual['DependentProductPaths']),set((actual['TestHostPath'],actual['TestBundlePath'],actual['UITargetAppPath'])))
    def test_changed_runner_structure_fails_closed(self):
        source=self.root/'wrong.xctestrun'
        tree={'TestConfigurations':[{'TestTargets':[{'BlueprintName':'FoqosUITests','IsUITestBundle':True}]}]}
        source.write_bytes(plistlib.dumps(tree))
        m.pin_xctestrun(source,self.root/'positive.xctestrun',{'bundle':'runner.xctrunner'},self.root/'runner.app',self.root/'v1.app')
        tree['TestConfigurations'][0]['TestTargets'][0]['BlueprintName']='FoqosTests'
        source.write_bytes(plistlib.dumps(tree))
        self.rejected(lambda: m.pin_xctestrun(source,self.root/'ui.xctestrun',{'bundle':'runner.xctrunner'},self.root/'runner.app',self.root/'v1.app'), 'fixtures out of date: unexpected external runner structure')
        self.assertFalse((self.root/'ui.xctestrun').exists())
    def runner(self):
        candidate=self.root/'candidate-runner.app'
        (candidate/'PlugIns/FoqosUITests.xctest').mkdir(parents=True)
        (candidate/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'example.runner.xctrunner','CFBundleShortVersionString':'1','CFBundleVersion':'1'}))
        source=self.root/'source.xctestrun'
        source.write_bytes(plistlib.dumps({'TestConfigurations':[{'TestTargets':[{'BlueprintName':'FoqosUITests','IsUITestBundle':True,'UITargetAppPath':'/stray/V2/Build/Products/app'}]}]}))
        m.entry(['install-runner',str(self.root),'--runner-app',str(candidate),'--xctestrun',str(source)])
    def test_prepare_run_rejects_changed_hashed_app_before_simulator_calls(self):
        self.seeded(); self.runner()
        (self.root/'v1.app/changed').write_text('tampered')
        self.calls.clear()
        self.rejected(lambda: m.entry(['prepare-run',str(self.root),'--phase','v1','--generation',self.udid]), 'pinned runner or phase app changed')
        self.assertEqual(self.calls,[])
    def test_prepare_v1_run_removes_stray_v2_products(self):
        self.seeded(); self.runner()
        self.calls.clear()
        m.entry(['prepare-run',str(self.root),'--phase','v1','--generation',self.udid])
        tree=plistlib.loads((self.root/f'v1.{self.udid}.xctestrun').read_bytes())
        target=tree['TestConfigurations'][0]['TestTargets'][0]
        self.assertEqual(target['UITargetAppPath'],str(self.root/'v1.app'))
        self.assertNotIn('/stray/V2',str(tree))
        self.assertEqual(self.calls,[])
    def test_post_run_version_mismatch_is_unrun_and_keeps_evidence(self):
        self.seeded()
        m.entry(['verify-run',str(self.root),'--phase','v1'])
        info=plistlib.loads((self.app/'Info.plist').read_bytes()); info['CFBundleVersion']='97'
        (self.app/'Info.plist').write_bytes(plistlib.dumps(info))
        self.rejected(lambda: m.entry(['verify-run',str(self.root),'--phase','v1']), 'UNRUN: installed app differs from pinned product')
        self.assertTrue((self.root/'v1-installed.json').exists())
    def test_post_run_sentinel_mismatch_is_unrun(self):
        self.v2()
        m.entry(['verify-run',str(self.root),'--phase','journey'])
        seed_path=self.data/'Documents/rc-v1-seed.json'
        seed=json.loads(seed_path.read_text()); seed['profiles'][0]['name']='Changed sentinel'
        seed_path.write_text(json.dumps(seed))
        self.rejected(lambda: m.entry(['verify-run',str(self.root),'--phase','journey']), 'UNRUN: V1 sentinel changed after the test')
    def test_post_run_correct_product_and_unchanged_sentinel(self):
        self.v2()
        m.entry(['verify-run',str(self.root),'--phase','journey'])

    def comparison(self):
        profile={'id':'original','name':'RC manual','schema':1,'isManaged':False,'domains':['example.com'],'enableBreaks':True,'breakTimeInMinutes':30,'reminderTimeInSeconds':300,'customReminderMessage':'RC retained reminder'}
        seed={'persona':'manual','mode':'individual','profiles':[profile],'sessionID':'active','session':{'id':'active','startTime':123,'breakStartTime':None},'historyID':'history','history':{'id':'history','startTime':10,'endTime':20},'emergencyRemaining':3,'emergencyWeeks':4}
        session={'id':'active','profileID':'original','startTime':123,'active':True,'breakStartTime':None}
        report={'profileCount':1,'activeSessionCount':1,'mode':'individual','syncEnabled':False,'profiles':[dict(profile)],'sessions':[session,{'id':'history','startTime':10,'endTime':20,'active':False}],'emergencyRemaining':3,'emergencyResetDays':28,'locations':[]}
        report['profiles'][0].update(needsMigration=True,invalid=False,newerSchema=False)
        return seed,report
    def test_hidden_first_launch_requires_original_session_and_deferred_conversion(self):
        seed,report=self.comparison()
        m.compare_report(seed,report,'first-launch')
        report['sessions'][0]['id']='replacement'
        self.rejected(lambda: m.compare_report(seed,report,'first-launch'), 'FAIL: first-launch: original session missing/replaced')
    def test_hidden_changed_break_or_refilled_emergency_fails(self):
        seed,report=self.comparison()
        seed['session']['breakStartTime']=120; report['sessions'][0]['breakStartTime']=120
        m.compare_report(seed,report,'first-launch')
        report['sessions'][0]['breakStartTime']=121
        self.rejected(lambda: m.compare_report(seed,report,'first-launch'), 'FAIL: first-launch: original session field changed: breakStartTime')
        report['sessions'][0]['breakStartTime']=120; report['emergencyRemaining']=4
        self.rejected(lambda: m.compare_report(seed,report,'first-launch'), 'FAIL: first-launch: emergency allowance changed/refilled')
    def test_hidden_lost_settings_and_history_fail(self):
        seed,report=self.comparison()
        m.compare_report(seed,report,'first-launch')
        report['profiles'][0]['domains']=[]
        self.rejected(lambda: m.compare_report(seed,report,'first-launch'), 'FAIL: first-launch: retained profile setting changed: domains')

        report['profiles'][0]['domains']=['example.com']; report['sessions'][1]['endTime']=21
        self.rejected(lambda: m.compare_report(seed,report,'first-launch'), 'FAIL: first-launch: completed history time changed')

    def rejected(self, action, message):
        with patch('sys.stderr', new_callable=io.StringIO) as output:
            with self.assertRaises(SystemExit) as error: action()
        self.assertEqual(error.exception.code, 1)
        self.assertIn('v1-v2-upgrade-state: ' + message, output.getvalue())

    def accepted(self, report):
        return {'sessions': {s['id']: {**s,'active':True,'schema':3} for s in report['sessions'] if s['id'] not in ('active','history')}}

    def test_stopped_origin_is_checked_from_active_supplement(self):
        seed,report=self.comparison()
        report['activeSessionCount']=0; report['sessions'][0]['active']=False
        report['profiles'][0].update(schema=3,needsMigration=False)
        report['sessions'].append({'id':'new','profileID':'original','startTime':456,'active':False,'origin':{'kind':'manual'}})
        supplement=self.accepted(report)
        report['sessions'][-1]['origin']=None
        m.compare_report(seed,report,'journey',supplement)
        supplement['sessions']['new']['origin']={'kind':'nfc'}
        self.rejected(lambda: m.compare_report(seed,report,'journey',supplement), 'FAIL: journey: post-update session did not originate through its required start method')

    def test_capture_rejects_report_older_than_ui_marker(self):
        report=self.v2()
        report.write_text(json.dumps({'phase':'first-launch','generation':self.udid,'persona':'manual','build':'97','version':'2.0.79','source':'a'*40,'count':1}))
        self.calls.clear()
        self.rejected(lambda: m.entry(['capture-v2',str(self.root),'--phase','first-launch','--generation',self.udid,'--report-count','2']), 'UNRUN: diagnostic report predates the UI completion marker')
        self.assertFalse(any(c[2]=='shutdown' for c in self.calls if c[0]=='xcrun'))

    def test_new_session_origin_and_exact_session_count(self):
        seed,report=self.comparison(); seed['persona']='nfc'
        report['activeSessionCount']=0; report['sessions'][0]['active']=False
        report['profiles'][0].update(schema=3,needsMigration=False)
        new={'id':'new','profileID':'original','startTime':456,'active':False,'origin':{'kind':'manual'}}
        report['sessions'].append(new)
        scans=[{'phase':'journey','generation':None,'kind':'nfc','requestIndex':i,'scriptIndex':i,'value':value} for i,value in enumerate(['wrong','correct','correct','correct'])]
        self.rejected(lambda: m.compare_report(seed,report,'journey',self.accepted(report),scan_entries=scans), 'FAIL: journey: post-update session did not originate through its required start method')
        new['origin']['kind']='nfc'
        m.compare_report(seed,report,'journey',self.accepted(report),scan_entries=scans)
        report['sessions'].append({**new,'id':'unexpected'})
        self.rejected(lambda: m.compare_report(seed,report,'journey',self.accepted(report),scan_entries=scans), 'FAIL: journey: session count changed')

    def test_child_created_manual_conditions_are_required(self):
        seed,report=self.comparison(); seed['persona']='child'
        report['activeSessionCount']=0; report['sessions'][0]['active']=False
        report['profiles'][0].update(schema=3,needsMigration=False)
        report['sessions'].append({'id':'new','profileID':'original','startTime':456,'active':False,'origin':{'kind':'manual'}})
        for key,name in [('created','RC Child Created'),('copy','RC child Copy')]:
            report['profiles'].append({'id':key,'name':name,'schema':3,'isManaged':False,'startTriggers':{'manual':True},'stopConditions':{'manual':True}})
        report['profileCount']=3
        accepted=self.accepted(report)
        m.compare_report(seed,report,'journey',accepted)
        for row in report['profiles'][1:]:
            for condition in ('startTriggers','stopConditions'):
                row[condition]['manual']=False
                self.rejected(lambda: m.compare_report(seed,report,'journey',accepted), 'FAIL: journey: Child-created/duplicated manual start or stop missing')
                row[condition]['manual']=True

    def test_scan_sequence_is_required_and_exhaustion_cannot_pass(self):
        seed,report=self.comparison(); seed['persona']='nfc'
        report['activeSessionCount']=0; report['sessions'][0]['active']=False
        report['profiles'][0].update(schema=3,needsMigration=False)
        report['sessions'].append({'id':'new','profileID':'original','startTime':456,'active':False,'origin':{'kind':'nfc'}})
        scans=[{'phase':'journey','generation':None,'kind':'nfc','requestIndex':i,'scriptIndex':i,'value':value} for i,value in enumerate(['wrong','correct','correct','correct'])]
        accepted=self.accepted(report)
        m.compare_report(seed,report,'journey',accepted,scan_entries=scans)
        self.rejected(lambda: m.compare_report(seed,report,'journey',accepted,scan_entries=[]), 'FAIL: journey: required scan delivery sequence differs')
        scans[-1]['value']='exhausted'
        self.rejected(lambda: m.compare_report(seed,report,'journey',accepted,scan_entries=scans), 'FAIL: journey: required scan delivery sequence differs')
        seed['persona']='manual'; report['sessions'][-1]['origin']['kind']='manual'
        accepted=self.accepted(report)
        m.compare_report(seed,report,'journey',accepted,scan_entries=[])
        self.rejected(lambda: m.compare_report(seed,report,'journey',accepted,scan_entries=[scans[0]]), 'FAIL: journey: required scan delivery sequence differs')

    def test_scans_reject_entries_from_other_phases(self):
        entries=[{'phase':'journey','generation':'fresh','kind':'nfc','requestIndex':i,'scriptIndex':i,'value':value} for i,value in enumerate(['wrong','correct','correct','correct'])]
        m.compare_scans('nfc','journey','fresh',entries)
        entries.append({'phase':'first-launch','generation':'earlier','kind':'nfc','requestIndex':0,'scriptIndex':0,'value':'correct'})
        self.rejected(lambda: m.compare_scans('nfc','journey','fresh',entries), 'FAIL: journey: required scan delivery sequence differs')
    def test_specific_stops_require_wrong_confirmation_and_correct_scan(self):
        for persona,kind in [('manual-nfc','nfc'),('manual-qr','qr')]:
            entries=[{'phase':'journey','generation':'fresh','kind':kind,'requestIndex':i,'scriptIndex':i,'value':value}
                     for i,value in enumerate(['wrong','correct','wrong','wrong','correct'])]
            m.compare_scans(persona,'journey','fresh',entries)
            self.rejected(lambda: m.compare_scans(persona,'journey','fresh',entries[:3]+entries[4:]), 'FAIL: journey: required scan delivery sequence differs')

    def test_non_scanner_relaunch_rejects_any_scan_history(self):
        m.compare_scans('manual','relaunch','fresh',[])
        entry={'phase':'journey','generation':'earlier','kind':'nfc','requestIndex':0,'scriptIndex':0,'value':'correct'}
        self.rejected(lambda: m.compare_scans('manual','relaunch','fresh',[entry]), 'FAIL: relaunch: required scan delivery sequence differs')

    def test_converted_schedule_recurrence_is_preserved(self):
        seed,report=self.comparison(); seed['persona']='schedule'
        schedule={'days':[1,2,3,4,5,6,7],'startHour':8,'startMinute':30,'endHour':17,'endMinute':45}
        seed['profiles'][0]['schedule']=schedule
        report['activeSessionCount']=0; report['sessions'][0]['active']=False
        report['sessions'].append({'id':'new','profileID':'original','startTime':456,'active':False,'origin':{'kind':'manual'}})
        row=report['profiles'][0]
        row.update(schema=3,needsMigration=False,startTriggers={'schedule':True},stopConditions={'schedule':True},scheduleLastStoppedAt=400,
                   startSchedule={'days':schedule['days'],'hour':8,'minute':30},stopSchedule={'days':schedule['days'],'hour':17,'minute':45})
        m.compare_report(seed,report,'journey',self.accepted(report))
        row['stopSchedule']['minute']=46
        self.rejected(lambda: m.compare_report(seed,report,'journey',self.accepted(report)), 'FAIL: journey: converted schedule recurrence changed')

    def test_preserve_products_is_immutable_and_touches_no_simulator(self):
        m.entry(['preserve-products',str(self.root),'--phase','v1','--source-revision','a'*40])
        self.assertEqual(self.calls,[])
        saved=(self.root/'v1.app/Info.plist').read_bytes()
        (self.product/'Info.plist').write_text('changed later build')
        self.assertEqual((self.root/'v1.app/Info.plist').read_bytes(),saved)
    def test_missing_generated_runner_preserves_app_and_evidence(self):
        (self.product/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':m.BUNDLE,'CFBundleShortVersionString':'2.0.79','CFBundleVersion':'97'}))
        self.rejected(lambda: m.entry(['preserve-products',str(self.root),'--phase','first-launch','--source-revision','a'*40]), 'fixtures out of date: expected one generated UI xctestrun')
        self.assertFalse((self.root/'v2.app').exists())
        self.assertEqual(self.store.read_text(),'prior store')
        self.assertEqual(self.calls,[])
    def test_optout_unchanged_report_passes_and_new_report_fails(self):
        report=self.v2(); report.write_text('{"old":"generation"}')
        m.entry(['begin-optout',str(self.root)])
        m.entry(['verify-optout',str(self.root)])
        report.write_text('{"unexpected":"new generation"}')
        self.rejected(lambda: m.entry(['verify-optout',str(self.root)]), 'FAIL: unflagged Debug created or changed the diagnostic report')
    def test_optout_missing_report_must_remain_missing(self):
        report=self.v2()
        m.entry(['begin-optout',str(self.root)])
        m.entry(['verify-optout',str(self.root)])
        report.write_text('{}')
        self.rejected(lambda: m.entry(['verify-optout',str(self.root)]), 'FAIL: unflagged Debug created or changed the diagnostic report')
    def test_timer_supplement_requires_actual_minute_aligned_deadline(self):
        seed,report=self.comparison(); seed['persona']='nfc-timer'
        report['activeSessionCount']=0; report['sessions'][0]['active']=False
        report['profiles'][0].update(schema=3,needsMigration=False)
        timer={'id':'new','profileID':'original','startTime':1234.5,'timerEndTime':3420,'active':True,'origin':{'kind':'manual'}}
        report['sessions'].append({**timer,'active':False,'timerEndTime':None})
        supplement={'sessions':{'new':{**timer,'schema':3}}}
        scans=[{'phase':'journey','generation':None,'kind':'nfc','requestIndex':i,'scriptIndex':i,'value':'correct'} for i in range(2)]
        m.compare_report(seed,report,'journey',supplement,scans)
        supplement['sessions']['new']['timerEndTime']=3454.5
        self.rejected(lambda: m.compare_report(seed,report,'journey',supplement,scans), 'FAIL: journey: accepted timer deadline differs from canonical minute boundary')
    def test_missing_timer_supplement_cannot_pass(self):
        seed,report=self.comparison(); seed['persona']='nfc-timer'
        report['activeSessionCount']=0; report['sessions'][0]['active']=False
        report['profiles'][0].update(schema=3,needsMigration=False)
        report['sessions'].append({'id':'new','profileID':'original','startTime':1234.5,'active':False,'origin':{'kind':'manual'}})
        scans=[{'phase':'journey','generation':None,'kind':'nfc','requestIndex':i,'scriptIndex':i,'value':'correct'} for i in range(2)]
        supplement=self.accepted(report); supplement['sessions']['new']['timerEndTime']=3420
        m.compare_report(seed,report,'journey',supplement,scan_entries=scans)
        del supplement['sessions']['new']['timerEndTime']
        self.rejected(lambda: m.compare_report(seed,report,'journey',supplement,scan_entries=scans), 'FAIL: journey: missing or duplicate accepted countdown')
    def timer_capture(self, *, stale):
        report=self.v2()
        state=json.loads((self.root/'prepared.json').read_text()); state['persona']='nfc-timer'
        (self.root/'prepared.json').write_text(json.dumps(state))
        for seed_path in (self.data/'Documents/rc-v1-seed.json',self.root/'v1-app-data/Documents/rc-v1-seed.json'):
            seed=json.loads(seed_path.read_text()); seed['persona']='nfc-timer'; seed_path.write_text(json.dumps(seed))
        value={'phase':'journey','generation':self.udid,'persona':'nfc-timer','source':'a'*40,'version':'2.0.79','build':'97','timeZone':'Europe/London','count':1}
        report.write_text(json.dumps(value))
        (self.data/'Documents/upgrade-session-report.json').write_text(json.dumps({**value,'generation':'stale' if stale else self.udid}))
        entries=[{'phase':'journey','generation':self.udid,'kind':'nfc','requestIndex':i,'scriptIndex':i,'value':'correct'} for i in range(2)]
        (self.data/'Documents/upgrade-scans.jsonl').write_text(''.join(json.dumps(entry)+'\n' for entry in entries))
        self.calls.clear()

    def test_stale_timer_supplement_is_unrun_before_capture_mutation(self):
        self.timer_capture(stale=True)
        self.rejected(lambda: m.entry(['capture-v2',str(self.root),'--report-count','1','--phase','journey','--generation',self.udid]), 'UNRUN: missing/stale/wrong-phase accepted session supplement')
        self.assertFalse(any(c[2] in ('shutdown','uninstall','install') for c in self.calls if c[0]=='xcrun'))
        self.assertTrue((self.root/'v1-app-group/Library/Application Support/default.store').is_file())

    def test_fresh_session_supplement_is_captured(self):
        self.timer_capture(stale=False)
        m.entry(['capture-v2',str(self.root),'--report-count','1','--phase','journey','--generation',self.udid])
    def test_missing_runtime_and_unauthorized_runtime_session_fail_closed(self):
        for fields,message in (({'IOS_SIM_GATE_RUNTIME_VERSION':''},'gate runtime version is missing or unusable'),({'IOS_SIM_GATE_SESSION':'collab-ios27'},'authorized collab-ios27 owner must actually run iOS 27')):
            with patch.dict(os.environ,fields):
                self.rejected(self.invoke, message)
        self.assertEqual(self.calls,[])
        self.assertEqual(self.store.read_text(),'prior store')
    def test_ios27_owner_accepts_another_agent_with_actual_runtime(self):
        dd=self.dd.parent/'session-collab-ios27'
        product=dd/'Build/Products/Debug-iphonesimulator/FamilyFoqos.app'
        shutil.copytree(self.product,product)
        with patch.dict(os.environ,{'IOS_SIM_GATE_SESSION':'collab-ios27','IOS_SIM_GATE_RUNTIME_VERSION':'27.0','IOS_SIM_GATE_DERIVED_DATA_PATH':str(dd)}):
            m.entry(['preserve-products',str(self.root),'--phase','v1','--source-revision','a'*40])
        self.assertTrue((self.root/'v1.app').exists())
        self.assertEqual(self.calls,[])
    def test_missing_gate_cannot_mutate(self):
        with patch.dict(os.environ, {'IOS_SIM_GATE_PROJECT':''}):
            self.rejected(self.invoke, 'requires the Family Foqos collab (or authorized collab-ios27) gate')
        self.assertEqual(self.store.read_text(), 'prior store')
    def test_sibling_derived_data_cannot_mutate(self):
        with patch.dict(os.environ, {'IOS_SIM_GATE_DERIVED_DATA_PATH':str(self.dd.parent/'session-other')}):
            self.rejected(self.invoke, 'refusing DerivedData outside this gate owner')
        self.assertEqual(self.store.read_text(), 'prior store')
    def test_container_escape_cannot_mutate(self):
        original = self.simctl
        def escape(*args, **kwargs):
            if args[0]=='xcrun' and args[2]=='get_app_container': return str(self.sibling).encode()
            return original(*args, **kwargs)
        with patch.object(m, 'run', side_effect=escape):
            self.rejected(self.invoke, 'refusing data container outside owned simulator')
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
        self.seeded(capture=False)
        m.entry(['verify-run',str(self.root),'--phase','v1'])
        seed=self.data/'Documents/rc-v1-seed.json'; seed.unlink()
        self.rejected(lambda: self.invoke('capture-v1'), 'unusable input/state: [Errno 2] No such file or directory:')
        self.assertFalse((self.root/'v1-app-data').exists())

unittest.main(argv=['upgrade-state-self-test'], verbosity=2)
PY
