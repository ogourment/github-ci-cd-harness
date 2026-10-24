#!/usr/bin/env python3
"""Read-only host probes; emits booleans and counts, never raw application logs."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.request


def run(argv, timeout=5):
    try:
        return subprocess.run(argv,capture_output=True,text=True,timeout=timeout,check=False)
    except (OSError, subprocess.SubprocessError):
        return None


def error_message(row):
    message=row.get('MESSAGE','')
    priority=str(row.get('PRIORITY','6'))
    return priority in ('0','1','2','3') or bool(re.search(
        r'\[(?:error|critical|alert|emergency)\]|Sent 5\d\d\b|Failed with result|Main process exited',message))


def application_error_count(rows):
    # Keep real request errors/crashes, but do not alert twice for our own
    # readiness HTTP status. Correlate by request_id, never suppress all 503s.
    health_requests = set()
    for row in rows:
        match = re.search(r'request_id=(\S+).*\bGET /health\s*$', row.get('MESSAGE', ''))
        if match:
            health_requests.add(match[1])
    count = 0
    for row in rows:
        message = row.get('MESSAGE', '')
        match = re.search(r'request_id=(\S+).*\[info\] Sent 503\b', message)
        if match and match[1] in health_requests:
            continue
        count += int(error_message(row))
    return count


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',required=True)
    parser.add_argument('--environment',required=True)
    args=parser.parse_args()
    config=json.loads(Path(args.config).read_text())
    app=config['environments'][args.environment]
    disk=os.statvfs(config['filesystem'])
    database=run(['runuser','-u','postgres','--','psql','-X','-At','-d',app['database'],'-c','SELECT 1;'])
    color=Path(app['color_file']).read_text().strip()
    application=False
    observation = {'result': 'invalid_slot', 'http_status': None, 'database': 'unknown'}
    started = time.monotonic()
    if color in ('blue','green'):
        try:
            with urllib.request.urlopen('http://127.0.0.1:'+str(app['ports'][color])+'/health',timeout=3) as response:
                payload = json.load(response)
                application=response.status == 200 and payload.get('status') == 'ok'
                observation.update(result='healthy' if application else 'unhealthy_response', http_status=response.status,
                    database=payload.get('database') if payload.get('database') in ('ok', 'unavailable') else 'unknown')
        except urllib.error.HTTPError as error:
            observation.update(result='http_error', http_status=error.code)
            try:
                payload = json.load(error)
                if payload.get('database') in ('ok', 'unavailable'):
                    observation['database'] = payload['database']
            except (ValueError, AttributeError):
                pass
        except (urllib.error.URLError, TimeoutError, OSError):
            observation['result'] = 'connection_failed'
        except (ValueError, AttributeError):
            observation['result'] = 'invalid_response'
    observation['elapsed_ms'] = round((time.monotonic()-started)*1000)
    backup_result=run(['systemctl','show',app['backup_unit'],'--property=Result','--value'])
    try:
        latest=Path(app['backup_latest']).resolve(strict=True)
        age=datetime.now(timezone.utc).timestamp()-latest.stat().st_mtime
        backup=backup_result is not None and backup_result.returncode == 0 and backup_result.stdout.strip() == 'success' and 0 <= age <= config['backup_max_age_seconds']
    except OSError:
        backup=False
    logs=run(['journalctl','-u',app['service_prefix']+'@'+color+'.service','--since','75 seconds ago','--no-pager','-o','json'])
    rows=[]
    if logs is not None and logs.returncode == 0:
        for row in logs.stdout.splitlines():
            try:
                rows.append(json.loads(row))
            except ValueError:
                pass
    else:
        raise RuntimeError('application log probe unavailable')
    errors=application_error_count(rows)
    observation['recent_service_start'] = any(
        re.search(r'Running .*Endpoint with|^Started .*service', row.get('MESSAGE', ''))
        for row in rows)
    result=dict(host=config['host'],observed_at=datetime.now(timezone.utc).isoformat(),
        disk={'free':disk.f_bavail*disk.f_frsize,'total':disk.f_blocks*disk.f_frsize},
        database=database is not None and database.returncode == 0 and database.stdout.strip() == '1',
        application=application,backup=backup,application_errors=errors,
        application_observation=observation)
    if config.get("maintenance_success_file"):
        check=run(["systemctl","show",config["maintenance_unit"],"--property=Result","--value"])
        try:
            age=datetime.now(timezone.utc).timestamp()-Path(config["maintenance_success_file"]).stat().st_mtime
            result["maintenance"]=check is not None and check.returncode == 0 and check.stdout.strip() == "success" and 0 <= age <= config["backup_max_age_seconds"]
        except OSError:
            result["maintenance"]=False
    print(json.dumps(result))


if __name__=='__main__':main()
