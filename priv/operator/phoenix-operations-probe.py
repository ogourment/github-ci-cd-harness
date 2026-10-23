#!/usr/bin/env python3
"""Read-only host probes; emits booleans and counts, never raw application logs."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
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
    if color in ('blue','green'):
        try:
            with urllib.request.urlopen('http://127.0.0.1:'+str(app['ports'][color])+'/health',timeout=3) as response:
                application=response.status == 200 and json.load(response).get('status') == 'ok'
        except Exception:
            pass
    backup_result=run(['systemctl','show',app['backup_unit'],'--property=Result','--value'])
    try:
        latest=Path(app['backup_latest']).resolve(strict=True)
        age=datetime.now(timezone.utc).timestamp()-latest.stat().st_mtime
        backup=backup_result is not None and backup_result.returncode == 0 and backup_result.stdout.strip() == 'success' and 0 <= age <= config['backup_max_age_seconds']
    except OSError:
        backup=False
    logs=run(['journalctl','-u',app['service_prefix']+'@'+color+'.service','--since','75 seconds ago','--no-pager','-o','json'])
    errors=0
    if logs is not None and logs.returncode == 0:
        for row in logs.stdout.splitlines():
            try:
                if error_message(json.loads(row)):
                    errors+=1
            except ValueError:
                pass
    else:
        raise RuntimeError('application log probe unavailable')
    result=dict(host=config['host'],observed_at=datetime.now(timezone.utc).isoformat(),
        disk={'free':disk.f_bavail*disk.f_frsize,'total':disk.f_blocks*disk.f_frsize},
        database=database is not None and database.returncode == 0 and database.stdout.strip() == '1',
        application=application,backup=backup,application_errors=errors)
    if config.get("maintenance_success_file"):
        check=run(["systemctl","show",config["maintenance_unit"],"--property=Result","--value"])
        try:
            age=datetime.now(timezone.utc).timestamp()-Path(config["maintenance_success_file"]).stat().st_mtime
            result["maintenance"]=check is not None and check.returncode == 0 and check.stdout.strip() == "success" and 0 <= age <= config["backup_max_age_seconds"]
        except OSError:
            result["maintenance"]=False
    print(json.dumps(result))


if __name__=='__main__':main()
