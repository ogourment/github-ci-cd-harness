import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, HTTPServer

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


class TransportDebounceTest(unittest.TestCase):
    def test_both_thresholds_are_required_and_first_observation_is_retained(self):
        start=datetime.now(timezone.utc)
        state={}
        self.assertEqual(monitor.transport_failure({},state,start),{})
        self.assertEqual(monitor.transport_failure({},state,start+timedelta(seconds=61)),{})
        self.assertEqual(monitor.transport_failure({},state,start+timedelta(seconds=62)),
                         {'observer_transport':'critical'})
        self.assertEqual(state['transport_failure']['first_observed_at'],start.isoformat())
        state={}
        for offset in (0,10,20):
            self.assertEqual(monitor.transport_failure({},state,start+timedelta(seconds=offset)),{})
        self.assertEqual(monitor.transport_failure({},state,start+timedelta(seconds=60)),
                         {'observer_transport':'critical'})
        state={}
        for offset in (0,30):
            self.assertEqual(monitor.transport_failure({},state,start+timedelta(seconds=offset)),{})
        self.assertEqual(monitor.transport_failure({},state,start+timedelta(seconds=60)),
                         {'observer_transport':'critical'})  # Exactly the third 30-second tick.

    def test_configurable_thresholds_are_validated_without_coercion(self):
        self.assertEqual(monitor.transport_thresholds({}),(3,60))
        self.assertEqual(monitor.transport_thresholds({'transport_failure_samples':2,
                         'transport_failure_seconds':30}),(2,30))
        for key,values in [('transport_failure_samples',[True,0,101,'3',1.5]),
                           ('transport_failure_seconds',[False,-1,3601,'60',float('inf')])]:
            for value in values:
                with self.subTest(key=key,value=value), self.assertRaises(ValueError):
                    monitor.transport_thresholds({key:value})


class MonitorProcessTest(unittest.TestCase):
    """Real CLI invocations, synthetic probe processes and a local receipt receiver."""
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.events=[]
        self.fail_delivery=False
        events=self.events
        owner=self
        class Receiver(BaseHTTPRequestHandler):
            def do_POST(self):
                events.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                if owner.fail_delivery:
                    owner.fail_delivery=False
                    self.send_response(503);self.end_headers();return
                self.send_response(202);self.end_headers()
                self.wfile.write(json.dumps({'event':{'id':str(len(events))}}).encode())
            def log_message(self,*args):
                pass
        self.server=HTTPServer(('127.0.0.1',0),Receiver)
        self.thread=threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.01),daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)
        self.token=self.root/'token';self.token.write_text('synthetic-test-token');self.token.chmod(0o600)
        self.sample=self.root/'sample.json'
        self.probe=self.root/'probe.py'
        self.probe.write_text('import pathlib,sys\n'
            'raw=pathlib.Path(sys.argv[1]).read_text()\n'
            'if raw == "exit":\n'
            '    print("SECRET stderr must stay private", file=sys.stderr)\n'
            '    sys.exit(7)\n'
            'print(raw)\n')
        self.state=self.root/'state.json'
        self.config=dict(app='synthetic',environment='test',host='synthetic',observer='test',
            probe_argv=[sys.executable,str(self.probe),str(self.sample)],
            token_file=str(self.token),state_file=str(self.state),
            a55ist_url=f'http://127.0.0.1:{self.server.server_port}')

    def close_server(self):
        self.server.shutdown();self.thread.join();self.server.server_close()

    def run_monitor(self, sample, success=True):
        self.sample.write_text(json.dumps(sample) if isinstance(sample,dict) else sample)
        config=self.root/'config.json';config.write_text(json.dumps(self.config))
        result=subprocess.run([sys.executable,str(ROOT/'priv/operator/phoenix-operations-monitor.py'),
            '--config',str(config)],capture_output=True,text=True,timeout=10)
        self.assertNotIn('SECRET',result.stdout+result.stderr)
        self.assertNotIn('synthetic-test-token',result.stdout+result.stderr)
        if not success:
            self.assertNotEqual(result.returncode,0)
            return result
        self.assertEqual(result.returncode,0,result.stderr)
        return json.loads(result.stdout.splitlines()[-1])

    def valid(self, application=True):
        return dict(host='synthetic',observed_at=datetime.now(timezone.utc).isoformat(),
            disk={'free':30,'total':100},database=True,application=application,
            backup=True,application_errors=0)

    def age_pending(self, seconds=61):
        state=json.loads(self.state.read_text())
        first=(datetime.now(timezone.utc)-timedelta(seconds=seconds)).isoformat()
        state['transport_failure']['first_observed_at']=first
        self.state.write_text(json.dumps(state))
        return first

    def test_single_failure_recovers_silently_and_resets_consecutive_count(self):
        self.assertEqual(self.run_monitor('exit')['transport_error'],'probe_exit')
        self.run_monitor(self.valid())
        self.assertEqual(self.events,[])
        self.assertNotIn('transport_failure',json.loads(self.state.read_text()))
        self.run_monitor('not JSON SECRET')
        self.assertEqual(json.loads(self.state.read_text())['transport_failure']['count'],1)
        self.assertEqual(self.events,[])

    def test_sustained_failure_alerts_once_then_recovers_same_episode(self):
        self.run_monitor('exit')
        first=self.age_pending()
        self.run_monitor('exit')
        self.assertEqual(self.events,[])  # Duration alone is insufficient.
        self.run_monitor('exit')
        self.assertEqual(len(self.events),1)
        firing=self.events[0]
        self.assertEqual(firing['reason_code'],'observer_transport')
        self.assertEqual(firing['status'],'firing')
        self.assertEqual(firing['metadata']['episode'],first)
        self.run_monitor('exit')
        self.assertEqual(len(self.events),1)
        self.run_monitor(self.valid())
        self.assertEqual(len(self.events),2)
        self.assertEqual(self.events[1]['status'],'recovered')
        self.assertEqual(self.events[1]['metadata']['correlation_key'],firing['metadata']['correlation_key'])
        self.assertNotIn('transport_failure',json.loads(self.state.read_text()))

    def test_unknown_sample_never_clears_application_failure(self):
        self.run_monitor(self.valid(application=False))
        self.run_monitor('exit')
        self.run_monitor('[]')
        malformed=self.valid();malformed['observed_at']=123
        self.assertEqual(self.run_monitor(malformed)['transport_error'],'invalid_sample')
        self.assertEqual([(e['reason_code'],e['status']) for e in self.events],
                         [('application','firing')])
        self.assertEqual(json.loads(self.state.read_text())['conditions']['application']['severity'],'critical')
        self.run_monitor(self.valid())
        self.assertEqual([(e['reason_code'],e['status']) for e in self.events],
                         [('application','firing'),('application','recovered')])

    def test_existing_alert_recovers_without_new_pending_counter(self):
        self.state.write_text(json.dumps({'conditions':{'observer_transport':
            {'severity':'critical','episode':'existing-episode','failure_observation':{}}}}))
        self.run_monitor(self.valid())
        self.assertEqual(len(self.events),1)
        self.assertEqual(self.events[0]['status'],'recovered')
        self.assertEqual(self.events[0]['metadata']['episode'],'existing-episode')

    def error_sample(self, errors=1):
        sample=self.valid()
        sample['application_errors']=errors
        return sample

    def age_error_recovery(self, seconds=61):
        state=json.loads(self.state.read_text())
        state['application_errors_recovery']['first_observed_at']=(
            datetime.now(timezone.utc)-timedelta(seconds=seconds)).isoformat()
        self.state.write_text(json.dumps(state))

    def test_error_log_episode_survives_restarts_until_count_and_clean_duration_are_met(self):
        self.run_monitor(self.error_sample())
        firing=self.events[0]
        self.assertEqual((firing['reason_code'],firing['status']),('application_errors','firing'))
        for _ in range(3):
            self.run_monitor(self.valid())
        self.assertEqual(self.events,[firing])  # Three fast samples are not sixty seconds.
        self.age_error_recovery()
        self.run_monitor(self.valid())
        self.assertEqual([event['status'] for event in self.events],['firing','recovered'])
        self.assertEqual(self.events[1]['metadata']['episode'],firing['metadata']['episode'])
        self.run_monitor(self.valid())
        self.assertEqual(len(self.events),2)

    def test_positive_error_burst_and_unknown_probe_each_break_the_clean_streak(self):
        self.run_monitor(self.error_sample(144))
        firing=self.events[0]
        for interruption in (self.error_sample(150),'exit'):
            self.run_monitor(self.error_sample())
            self.run_monitor(self.valid())
            self.run_monitor(self.valid())
            self.age_error_recovery()
            self.run_monitor(interruption)
            self.run_monitor(self.valid())
            self.age_error_recovery()
            self.run_monitor(self.valid())
            self.assertEqual(self.events,[firing])  # Duration alone cannot close the episode.
        self.run_monitor(self.valid())
        self.assertEqual([event['status'] for event in self.events],['firing','recovered'])
        self.assertEqual(self.events[1]['metadata']['episode'],firing['metadata']['episode'])

    def test_error_recovery_wait_preserves_immediate_critical_checks(self):
        self.run_monitor(self.error_sample())
        self.run_monitor(self.valid())
        sample=self.valid(application=False)
        sample['database']=False
        sample['disk']['free']=4
        self.run_monitor(sample)
        self.assertEqual([(event['reason_code'],event['severity']) for event in self.events],
                         [('application_errors','error'),('disk','critical'),
                          ('database','critical'),('application','critical')])

    def test_failed_error_recovery_retries_the_exact_payload_after_restart(self):
        self.run_monitor(self.error_sample())
        self.run_monitor(self.valid())
        self.age_error_recovery()
        self.run_monitor(self.valid())
        self.fail_delivery=True
        self.run_monitor(self.valid(),success=False)
        pending=json.loads(self.state.read_text())['pending']
        self.assertEqual(pending['status'],'recovered')
        self.assertEqual(pending,self.events[-1])
        self.run_monitor(self.valid())
        self.assertEqual(self.events[-2:], [pending,pending])
        self.assertNotIn('pending',json.loads(self.state.read_text()))

    def test_failed_delivery_retries_identical_payload_before_recovery(self):
        self.config.update(transport_failure_samples=1,transport_failure_seconds=0)
        self.fail_delivery=True
        self.run_monitor('exit',success=False)
        pending=json.loads(self.state.read_text())['pending']
        self.assertEqual(pending,self.events[0])
        self.run_monitor(self.valid())
        self.assertEqual(len(self.events),3)
        self.assertEqual(self.events[0],self.events[1])
        self.assertEqual(self.events[2]['status'],'recovered')
        state=json.loads(self.state.read_text())
        self.assertNotIn('pending',state)
        self.assertEqual(len(state['receipts']),2)

if __name__=='__main__':unittest.main()
