#!/usr/bin/env python3
"""Independent probes and durable alert-event.v1 delivery through A55ist.

Run on a healthy observer host, never inside the observed app or database.
Configuration names an argv probe returning timestamped JSON and a private
producer token file. No application logs or credentials enter alert payloads.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request


def utcnow():
    return datetime.now(timezone.utc)


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def conditions(config, sample, now=None):
    now = now or utcnow()
    observed = datetime.fromisoformat(sample['observed_at'].replace('Z', '+00:00'))
    if observed.tzinfo is None or not -5 <= (now-observed).total_seconds() <= 120:
        raise ValueError('stale or future probe')
    if sample['host'] != config['host']:
        raise ValueError('wrong probe host')
    disk = sample['disk']
    if type(disk['free']) is not int or type(disk['total']) is not int or not 0 <= disk['free'] <= disk['total'] or disk['total'] <= 0:
        raise ValueError('invalid disk probe')
    result = {'disk': ('critical' if disk['free']*100 < disk['total']*10 else 'warning')
              if disk['free']*100 < disk['total']*20 else None}
    for name in ('database', 'application', 'backup') + (('maintenance',) if 'maintenance' in sample else ()):
        if type(sample[name]) is not bool:
            raise ValueError('unknown probe is not health: '+name)
        result[name] = None if sample[name] else 'critical'
    errors = sample['application_errors']
    if type(errors) is not int or errors < 0:
        raise ValueError('invalid application error count')
    result['application_errors'] = 'error' if errors else None
    return result


def observation(sample):
    """Explicit allowlist: raw journals, credentials and exception text stay local."""
    if not sample:
        return {}
    result = {key: sample[key] for key in ('observed_at', 'database', 'application',
        'backup', 'maintenance', 'application_errors', 'disk') if key in sample}
    app = sample.get('application_observation', {})
    result['application_observation'] = {key: app[key] for key in
        ('result', 'http_status', 'database', 'elapsed_ms', 'recent_service_start') if key in app}
    return result


def description(name, sample):
    titles = {'application': 'Application readiness check failed',
        'application_errors': 'Application error log entries detected',
        'database': 'Direct PostgreSQL check failed', 'disk': 'Free disk space is low',
        'backup': 'Backup is failed or older than its allowed age',
        'maintenance': 'Retention maintenance is failed or stale',
        'observer_transport': 'Observer could not obtain a valid host sample'}
    detail = titles.get(name, name+' check failed')
    if name == 'application' and sample:
        app = sample.get('application_observation', {})
        if app.get('http_status'):
            detail += f"; /health returned HTTP {app['http_status']}"
        detail += f"; app database: {app.get('database', 'unknown')}"
        detail += '; direct PostgreSQL: '+('healthy' if sample.get('database') else 'failed')
        if app.get('recent_service_start'):
            detail += '; service startup observed in the last 75 seconds'
    if name == 'application_errors' and sample:
        detail += f"; {sample['application_errors']} entries in the last 75 seconds (readiness status excluded)"
    return detail


def event(config, name, severity, episode, recovered=False, sample=None, failure=None):
    status = 'recovered' if recovered else 'firing'
    fingerprint = ':'.join([config['app'], config['environment'], config['host'], name])
    return dict(contract_version='alert-event.v1', app=config['app'],
        environment=config['environment'], host=config['host'], source='phoenix-operations-monitor',
        category='operations', reason_code=name, severity='info' if recovered else severity,
        status=status, occurred_at=utcnow().isoformat(), occurred_timezone='UTC',
        fingerprint=fingerprint, idempotency_key=fingerprint+':'+episode+':'+status+':'+str(severity),
        message=("REHEARSAL (production unchanged): " if config.get("rehearsal") else "")+
            (f"{name.replace('_', ' ').capitalize()} recovered" if recovered else description(name, sample)),
        metadata={'observer':config['observer'], 'episode':episode,
            'correlation_key':fingerprint+':'+episode,
            'alerts_url':config.get('a55ist_url', '').rstrip('/')+'/ops/alerts'},
        evidence={'observation':observation(sample), 'initial_failure':failure or {}})


def deliver(config, payload):
    token_path = Path(config['token_file'])
    if token_path.stat().st_mode & 0o077:
        raise ValueError('producer token file must be private')
    req = urllib.request.Request(config['a55ist_url'].rstrip('/')+'/api/alerts',
        data=json.dumps(payload).encode(), headers={'Content-Type':'application/json',
        'Authorization':'Bearer '+token_path.read_text().strip()}, method='POST')
    with urllib.request.urlopen(req, timeout=10) as response:
        receipt = json.load(response)
        if response.status != 202 or not receipt.get('event', {}).get('id'):
            raise ValueError('missing receiver event receipt')
        return receipt['event']['id']


def transport_thresholds(config):
    samples = config.get('transport_failure_samples', 3)
    seconds = config.get('transport_failure_seconds', 60)
    if type(samples) is not int or not 1 <= samples <= 100:
        raise ValueError('transport_failure_samples must be an integer from 1 to 100')
    if type(seconds) is not int or not 0 <= seconds <= 3600:
        raise ValueError('transport_failure_seconds must be an integer from 0 to 3600')
    return samples, seconds


def transport_failure(config, state, now):
    """Unknown samples leave application conditions untouched, including failures."""
    minimum_samples, minimum_seconds = transport_thresholds(config)
    pending = state.setdefault('transport_failure', {'count': 0, 'first_observed_at': now.isoformat()})
    pending['count'] += 1
    first = datetime.fromisoformat(pending['first_observed_at'])
    already_firing = state.get('conditions', {}).get('observer_transport', {}).get('severity')
    if already_firing or (pending['count'] >= minimum_samples and
            (now-first).total_seconds() >= minimum_seconds):
        return {'observer_transport': 'critical'}
    return {}


def transport_error_category(error):
    # Exception messages, subprocess stderr and probe output may contain secrets.
    if isinstance(error, subprocess.TimeoutExpired):
        return 'probe_timeout'
    if isinstance(error, subprocess.CalledProcessError):
        return 'probe_exit'
    if isinstance(error, OSError):
        return 'probe_io'
    return 'invalid_sample'


def coalesce_application_error_recovery(findings, state, now):
    """Keep bursty log errors in one episode until sustained valid quiet."""
    active = state.get('conditions', {}).get('application_errors', {}).get('severity')
    if findings['application_errors'] or not active:
        state.pop('application_errors_recovery', None)
        return findings
    clean = state.setdefault('application_errors_recovery',
        {'count': 0, 'first_observed_at': now.isoformat()})
    clean['count'] += 1
    first = datetime.fromisoformat(clean['first_observed_at'])
    if clean['count'] >= 3 and (now-first).total_seconds() >= 60:
        state.pop('application_errors_recovery')
        return findings
    # Omitting this finding preserves the active severity and its original
    # episode. Independent readiness, database and disk findings stay immediate.
    return {name: severity for name, severity in findings.items() if name != 'application_errors'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--sample', help='use a labelled rehearsal JSON sample')
    args=parser.parse_args()
    config=json.loads(Path(args.config).read_text())
    transport_thresholds(config)
    state_path=Path(config['state_file'])
    state_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(str(state_path)+'.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state=json.loads(state_path.read_text()) if state_path.exists() else {}
        # Retry a bounded pending delivery with the identical receiver idempotency key.
        if state.get('pending'):
            payload=state['pending']
            receipt=deliver(config,payload)
            state['receipts']=(state.get('receipts',[])+[{'event_id':receipt,'key':payload['idempotency_key']}])[-100:]
            state.pop('pending')
            atomic(state_path,state)
        sample=None
        transport_error=None
        try:
            raw=Path(args.sample).read_text() if args.sample else subprocess.run(
                config['probe_argv'],capture_output=True,text=True,check=True,timeout=30).stdout
            sample=json.loads(raw)
            findings=conditions(config,sample)
            findings=coalesce_application_error_recovery(findings,state,utcnow())
            findings['observer_transport']=None
            state.pop('transport_failure', None)
        except (ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError, OSError) as error:
            sample=None
            state.pop('application_errors_recovery', None)
            transport_error=transport_error_category(error)
            findings=transport_failure(config,state,utcnow())
        for name,severity in findings.items():
            previous=state.get('conditions',{}).get(name,{})
            was_firing=bool(previous.get('severity'))
            if not severity and not was_firing:
                continue
            # Valid host failures and severity increases are immediate. Only
            # error-log recovery waits for sustained quiet. A55ist
            # retains incident/delivery receipts and handles reminder coalescing.
            if severity == previous.get('severity'):
                continue
            episode=previous.get('episode') if was_firing else utcnow().isoformat()
            if name == 'observer_transport' and not was_firing:
                episode=state['transport_failure']['first_observed_at']
            failure=previous.get('failure_observation') if was_firing else observation(sample)
            payload=event(config,name,severity,episode,recovered=not severity, sample=sample, failure=failure)
            state.setdefault('conditions',{})[name]={'severity':severity,'episode':episode,
                'failure_observation':failure}
            state['pending']=payload
            atomic(state_path,state)
            receipt=deliver(config,payload)
            state['receipts']=(state.get('receipts',[])+[{'event_id':receipt,'key':payload['idempotency_key']}])[-100:]
            state.pop('pending')
            atomic(state_path,state)
            print(json.dumps({'condition':name,'status':payload['status'],'event_id':receipt}),flush=True)
        state['checked_at']=utcnow().isoformat()
        atomic(state_path,state)
        diagnostic={'checked_at':state['checked_at'],'conditions':findings}
        if transport_error:
            diagnostic['transport_error']=transport_error
            diagnostic['transport_failure']=state['transport_failure']
        print(json.dumps(diagnostic),flush=True)


if __name__=='__main__':
    main()
