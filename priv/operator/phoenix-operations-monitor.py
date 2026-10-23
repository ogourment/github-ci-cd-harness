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


def event(config, name, severity, episode, recovered=False):
    status = 'recovered' if recovered else 'firing'
    fingerprint = ':'.join([config['app'], config['environment'], config['host'], name])
    return dict(contract_version='alert-event.v1', app=config['app'],
        environment=config['environment'], host=config['host'], source='phoenix-operations-monitor',
        category='operations', reason_code=name, severity='info' if recovered else severity,
        status=status, occurred_at=utcnow().isoformat(), occurred_timezone='UTC',
        fingerprint=fingerprint, idempotency_key=fingerprint+':'+episode+':'+status+':'+str(severity),
        message=("REHEARSAL (production unchanged): " if config.get("rehearsal") else "")+f"{config['app']} / {config['environment']}: {name} {'recovered' if recovered else 'failed'}",
        metadata={'observer':config['observer'], 'episode':episode}, evidence={})


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


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--sample', help='use a labelled rehearsal JSON sample')
    args=parser.parse_args()
    config=json.loads(Path(args.config).read_text())
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
        try:
            raw=Path(args.sample).read_text() if args.sample else subprocess.run(
                config['probe_argv'],capture_output=True,text=True,check=True,timeout=30).stdout
            findings=conditions(config,json.loads(raw))
            findings['observer_transport']=None
        except (ValueError, KeyError, subprocess.SubprocessError, OSError):
            findings={'observer_transport':'critical'}
        for name,severity in findings.items():
            previous=state.get('conditions',{}).get(name,{})
            was_firing=bool(previous.get('severity'))
            if not severity and not was_firing:
                continue
            # Every firing transition and severity increase is immediate. A55ist
            # retains incident/delivery receipts and handles reminder coalescing.
            if severity == previous.get('severity'):
                continue
            episode=previous.get('episode') if was_firing else utcnow().isoformat()
            payload=event(config,name,severity,episode,recovered=not severity)
            state.setdefault('conditions',{})[name]={'severity':severity,'episode':episode}
            state['pending']=payload
            atomic(state_path,state)
            receipt=deliver(config,payload)
            state['receipts']=(state.get('receipts',[])+[{'event_id':receipt,'key':payload['idempotency_key']}])[-100:]
            state.pop('pending')
            atomic(state_path,state)
            print(json.dumps({'condition':name,'status':payload['status'],'event_id':receipt}),flush=True)
        state['checked_at']=utcnow().isoformat()
        atomic(state_path,state)
        print(json.dumps({'checked_at':state['checked_at'],'conditions':findings}),flush=True)


if __name__=='__main__':
    main()
