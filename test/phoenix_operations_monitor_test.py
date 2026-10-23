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

    def test_app_error_and_backup_are_independent(self):
        s=self.sample();s['application_errors']=1;s['backup']=False
        r=monitor.conditions({'host':'synthetic'},s)
        self.assertEqual(r['application_errors'],'error');self.assertEqual(r['backup'],'critical');self.assertIsNone(r['application'])

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
