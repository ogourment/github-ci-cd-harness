import importlib.util
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timezone, timedelta

ROOT=Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'priv/operator'/f'{name}.py')
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod
monitor=module('phoenix-operations-monitor')
pruner=module('phoenix-release-prune')

class OperationsTest(unittest.TestCase):
    def sample(self):
        return dict(host='synthetic',observed_at=datetime.now(timezone.utc).isoformat(),disk={'free':30,'total':100},database=True,application=True,backup=True,application_errors=0)

    def test_independent_database_failure_and_disk_thresholds(self):
        s=self.sample();s['disk']['free']=4;s['database']=False
        r=monitor.conditions({'host':'synthetic'},s)
        self.assertEqual(r['disk'],'critical');self.assertEqual(r['database'],'critical')
        s['disk']['free']=19;self.assertEqual(monitor.conditions({'host':'synthetic'},s)['disk'],'warning')
        s['disk']['free']=20;self.assertIsNone(monitor.conditions({'host':'synthetic'},s)['disk'])

    def test_unknown_stale_and_wrong_host_fail_closed(self):
        for field,value in [('database',None),('host','other'),('observed_at',(datetime.now(timezone.utc)-timedelta(minutes=3)).isoformat())]:
            s=self.sample();s[field]=value
            with self.assertRaises(ValueError):monitor.conditions({'host':'synthetic'},s)

    def test_bounded_ntp_skew_is_accepted_but_future_samples_are_rejected(self):
        s=self.sample();s['observed_at']=(datetime.now(timezone.utc)+timedelta(seconds=2)).isoformat()
        self.assertIsNone(monitor.conditions({'host':'synthetic'},s)['database'])
        s['observed_at']=(datetime.now(timezone.utc)+timedelta(seconds=10)).isoformat()
        with self.assertRaises(ValueError):monitor.conditions({'host':'synthetic'},s)

    def test_app_error_and_backup_are_independent(self):
        s=self.sample();s['application_errors']=1;s['backup']=False
        r=monitor.conditions({'host':'synthetic'},s)
        self.assertEqual(r['application_errors'],'error');self.assertEqual(r['backup'],'critical');self.assertIsNone(r['application'])

    def test_systemd_crash_is_seen_even_after_automatic_restart(self):
        probe=module('phoenix-operations-probe')
        self.assertTrue(probe.error_message({'MESSAGE':'Main process exited, code=killed, status=9/KILL','PRIORITY':'6'}))
        self.assertTrue(probe.error_message({'MESSAGE':'unit failed','PRIORITY':'3'}))
        self.assertTrue(probe.error_message({'MESSAGE':'Sent 500 in 3ms','PRIORITY':'6'}))
        self.assertFalse(probe.error_message({'MESSAGE':'Stopped cleanly','PRIORITY':'6'}))

    def test_readiness_status_is_not_a_second_error_but_real_errors_remain(self):
        probe=module('phoenix-operations-probe')
        rows=[{'MESSAGE':'request_id=health [info] GET /health'},
              {'MESSAGE':'request_id=health [info] Sent 503 in 5ms'}]
        self.assertEqual(probe.application_error_count(rows),0)
        rows += [{'MESSAGE':'request_id=other [info] Sent 503 in 5ms'},
                 {'MESSAGE':'request_id=health [error] actual exception'},
                 {'MESSAGE':'Main process exited, code=killed'}]
        self.assertEqual(probe.application_error_count(rows),3)

    def test_events_explain_observation_correlate_recovery_and_exclude_raw_logs(self):
        c=dict(app='test',environment='test',host='synthetic',observer='test',a55ist_url='https://operator.example')
        s=self.sample();s['application']=False
        s['application_observation']=dict(result='http_error',http_status=503,database='unavailable',elapsed_ms=5,raw='private')
        s['journal']='private'
        firing=monitor.event(c,'application','critical','episode',sample=s)
        recovery=monitor.event(c,'application',None,'episode',True,s,monitor.observation(s))
        self.assertIn('HTTP 503',firing['message'])
        self.assertIn('direct PostgreSQL: healthy',firing['message'])
        self.assertEqual(firing['metadata']['correlation_key'],recovery['metadata']['correlation_key'])
        self.assertNotEqual(firing['idempotency_key'],recovery['idempotency_key'])
        self.assertEqual(firing['metadata']['alerts_url'],'https://operator.example/ops/alerts')
        self.assertNotIn('private',str(firing))
        self.assertEqual(recovery['evidence']['initial_failure']['application_observation']['http_status'],503)

    def test_failed_maintenance_is_its_own_optional_condition(self):
        s=self.sample();s['maintenance']=False
        self.assertEqual(monitor.conditions({'host':'synthetic'},s)['maintenance'],'critical')

    def test_recovery_contract_and_severity_escalation_keys(self):
        c=dict(app='test',environment='test',host='synthetic',observer='test')
        a=monitor.event(c,'disk','warning','episode');b=monitor.event(c,'disk','critical','episode')
        self.assertNotEqual(a['idempotency_key'],b['idempotency_key'])
        self.assertEqual(a['fingerprint'],b['fingerprint'])
        self.assertEqual(monitor.event(c,'disk',None,'episode',True)['status'],'recovered')

    def test_prune_protects_both_slots_even_when_old_and_rejects_symlink_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'releases';root.mkdir()
            for i in range(5):(root/f'app-0.1.{i}-{100+i}').mkdir()
            slots=[]
            for i in range(2):
                slot=Path(tmp)/f'slot-{i}';slot.symlink_to(root/f'app-0.1.{i}-{100+i}');slots.append(slot)
            selected=pruner.plan([root],slots)
            self.assertNotIn(str(root/'app-0.1.0-100'),selected)
            self.assertNotIn(str(root/'app-0.1.1-101'),selected)
            bad=Path(tmp)/'alias';bad.symlink_to(root)
            with self.assertRaises(ValueError):pruner.plan([bad],slots)
            (root/'unexpected').mkdir()
            with self.assertRaises(ValueError):pruner.plan([root],slots)


class EvidenceCapacityTest(unittest.TestCase):
    def test_metadata_retained_and_newest_two_payloads_protected(self):
        trim=module('phoenix-evidence-trim')
        with tempfile.TemporaryDirectory() as tmp:
            for i in range(5):
                r=Path(tmp)/f'run-{i}';r.mkdir();(r/'screenshots').mkdir()
                (r/'screenshots/x.png').write_bytes(b'x'*10)
                (r/'evidence.json').write_text(__import__('json').dumps({'run':{'id':r.name},'generated_at':f'2026-10-{10+i}T00:00:00Z'}))
            retained,evict=trim.plan(tmp,20)
            self.assertEqual(retained,20);self.assertEqual(len(evict),3)
            self.assertTrue(all((r/'evidence.json').exists() for r,_,_ in evict))
            for r,files,_ in evict:
                self.assertNotIn(r.name,['run-3','run-4'])
            (Path(tmp)/'run-0/screenshots/unsafe').symlink_to('/etc/passwd')
            with self.assertRaises(ValueError):trim.plan(tmp,20)

if __name__=='__main__':unittest.main()
