import os,tempfile,subprocess,json,pathlib,time
from jinja2 import Environment,StrictUndefined
import sys
root=pathlib.Path(__file__).resolve().parents[1]
template=root/'priv/ansible/roles/phoenix_blue_green/templates/phoenix_health_watch.sh.j2'
start=time.monotonic()
results=[]
for version in ['candidate']:
 for scenario in (['public-dns','public-smoke','direct-app','standby-failover'] + (['public-notify-retry'] if version == 'candidate' else [])):
  with tempfile.TemporaryDirectory(prefix='atqc-watchdog-fakes-') as t:
   p=pathlib.Path(t);(p/'bin').mkdir();(p/'state').mkdir();(p/'color').write_text('blue\n');(p/'upstream').write_text('upstream demo {server 127.0.0.1:4000;}\n')
   vals={'app_health_watch_script':str(p/'watchdog.sh'),'app_name':'demo','deploy_env':'test','deploy_user':'test','app_current_color_file':str(p/'color'),'nginx_upstream_include':str(p/'upstream'),'nginx_upstream_name':'demo','telegram_notify_script':str(p/'bin'/'notify'),'app_failure_history_path':str(p/'history'),'app_health_watch_state_dir':str(p/'state'),'deploy_operation_lock_path':str(p/'lock'),'app_port_blue':4000,'app_port_green':4001,'deploy_health_path':'/api/health/ready','deploy_public_base_url':'https://public.invalid','deploy_public_smoke_path':'/','deploy_public_smoke_content_type':'text/html','deploy_public_smoke_timeout_sec':3,'app_health_watch_failure_threshold':2,'app_health_watch_action_cooldown_sec':300,'nginx_upstream_max_fails':1,'nginx_upstream_fail_timeout':'5s','nginx_upstream_keepalive':0}
   rendered=Environment(undefined=StrictUndefined).from_string(template.read_text()).render(vals)
   script=p/'watchdog.sh';script.write_text(rendered)
   subprocess.run(['/bin/bash','-n',str(script)],check=True)
   fakecurl='''#!/usr/bin/env python3
import os,sys,json,pathlib
args=sys.argv[1:];url=args[-1]
def option(key):
 return args[args.index(key)+1] if key in args else None
mode=os.environ['SIM_MODE'];public=url.startswith('https:');standby=':4001' in url
failure=(public and mode=='public-dns') or (public and mode=='public-smoke' and not url.endswith('/ready')) or (not public and not standby and mode in ['direct-app','standby-failover']) or (standby and mode not in ['standby-failover','healthy'])
if failure:
 print('curl: simulated transport failure',file=sys.stderr);print('000',end='');raise SystemExit(6 if public else 7)
out=option('--output')
if out and out!='/dev/null': pathlib.Path(out).write_text(json.dumps({'color':pathlib.Path(os.environ['SIM_COLOR']).read_text().strip() if public else ('green' if standby else 'blue')}) if url.endswith('/ready') else '<!doctype html><html>test</html>')
headers=option('--dump-header')
if headers: pathlib.Path(headers).write_text('Content-Type: text/html\\r\\n')
print('200',end='')
'''
   files={'curl':fakecurl,'flock':'#!/bin/sh\nexit 0\n','chown':'#!/bin/sh\nexit 0\n','nginx':'#!/bin/sh\necho "nginx $*" >> "$SIM_ACTIONS"\nexit 0\n','notify':'#!/bin/sh\nif [ "$SIM_SCENARIO" = public-notify-retry ] && [ "$SIM_NOW" = 1001 ]; then echo notify_failed >> "$SIM_ACTIONS"; exit 1; fi\necho "notify" >> "$SIM_ACTIONS"\n','systemctl':'#!/bin/sh\nif [ "$1" = is-active ]; then [ "$SIM_MODE" = standby-failover ]; exit $?; fi\necho "systemctl $*" >> "$SIM_ACTIONS"\n','date':'#!/bin/sh\nif [ "$2" = +%s ]; then echo "$SIM_NOW"; else /bin/date "$@"; fi\n'}
   fakecurl=fakecurl.replace('#!/usr/bin/env python3', '#!'+sys.executable)
   files['curl']=fakecurl
   for name,data in files.items(): f=p/'bin'/name;f.write_text(data);f.chmod(0o700)
   env=os.environ.copy();env.update(PATH=str(p/'bin')+':'+env['PATH'],SIM_ACTIONS=str(p/'actions'),SIM_COLOR=str(p/'color'),SIM_SCENARIO=scenario)
   probes=[(1000,scenario),(1001,scenario),(1002,'healthy'),(1003,scenario),(1004,scenario)]
   logs=[]
   for now,mode in probes:
    env.update(SIM_NOW=str(now),SIM_MODE='public-dns' if mode=='public-notify-retry' else mode)
    r=subprocess.run(['/bin/bash',str(script)],env=env,text=True,capture_output=True,timeout=10)
    assert r.returncode==0,(version,scenario,r.stderr)
    logs.append(r.stdout.strip())
   actions=(p/'actions').read_text().splitlines() if (p/'actions').exists() else []
   recovery=[a for a in actions if a.startswith('systemctl restart') or a.startswith('nginx -s reload')]
   notices=sum(a=='notify' for a in actions)
   if version=='candidate':
    expected=0 if scenario.startswith('public') else 1
    assert len(recovery)==expected,(scenario,actions,logs)
    assert (p/'state'/'last-action').exists()==(expected==1)
    if scenario.startswith('public'):
     assert notices==1 # isolated healthy probe does not close a flapping issue
     history=[json.loads(x) for x in (p/'history').read_text().splitlines()]
     assert all('healthy active service retained' in x['action'] for x in history)
     assert all('curl_exit=6' in x['reason'] for x in history)
    else: assert notices==1
   if version == 'candidate' and scenario.startswith('public'):
    for now,mode in [(1100,'healthy'),(1160,'healthy'),(1161,scenario),(1162,scenario)]:
     env.update(SIM_NOW=str(now),SIM_MODE='public-dns' if mode=='public-notify-retry' else mode)
     r=subprocess.run(['/bin/bash',str(script)],env=env,text=True,capture_output=True,timeout=10)
     assert r.returncode==0,(scenario,r.stderr)
     logs.append(r.stdout.strip())
    actions=(p/'actions').read_text().splitlines()
    assert sum(a=='notify' for a in actions)==2,(scenario,actions,logs)
    assert not any(a.startswith('systemctl restart') or a.startswith('nginx -s reload') for a in actions)
    if scenario=='public-notify-retry': assert actions.count('notify_failed')==1
    notices=2
   results.append({'template':version,'scenario':scenario,'probes':len(logs),'service_recovery_actions':len(recovery),'notifications':notices,'logs':logs})
report={'scope':'Exact original/candidate Jinja template; every network, service, proxy, notification, ownership and lock operation faked. No live mutation.','elapsed_seconds':round(time.monotonic()-start,3),'cases':results}
# Results go to stdout; do not create generated artifacts in the checkout.
print(json.dumps(report,indent=2))
