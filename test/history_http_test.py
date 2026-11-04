"""Offline historical transport contracts; synthetic authentication only."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

HELPER = Path(__file__).resolve().parents[1] / "priv/forges/gitlab/history_http.sh"
TOKEN = "SYNTHETIC-HISTORY-TOKEN"
CURL = r'''#!/usr/bin/env python3
import os,sys,time,pathlib
args=sys.argv[1:]
assert os.environ['HISTORY_HTTP_TOKEN'] not in ' '.join(args)
assert args[args.index('--header')+1]=='@-'
assert args[args.index('--max-redirs')+1]=='0'
assert args[args.index('--retry')+1]=='0'
assert float(args[args.index('--connect-timeout')+1])<=5
assert float(args[args.index('--max-time')+1])<=15
assert sys.stdin.read()=='PRIVATE-TOKEN: '+os.environ['HISTORY_HTTP_TOKEN']+'\n'
with open(os.environ['CALL_LOG'],'a') as f:f.write('curl\n')
if os.environ['MODE']=='denied':
 print('untrusted partial');print(os.environ['HISTORY_HTTP_TOKEN'],file=sys.stderr);sys.exit(22)
if os.environ['MODE']=='hang':time.sleep(10)
print('payload')
'''
GLAB = r'''#!/usr/bin/env python3
import os,time
with open(os.environ['CALL_LOG'],'a') as f:f.write('glab\n')
if os.environ['MODE']=='hang':time.sleep(10)
print('payload')
'''


class HistoryHTTPTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for name, body in [('curl', CURL), ('glab', GLAB)]:
            p = self.root / name
            p.write_text(body)
            p.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.root)+os.pathsep+os.environ['PATH'],
                        HISTORY_HTTP_API_ROOT='https://fixture.invalid/api/v4',
                        HISTORY_HTTP_AUTH_HEADER='PRIVATE-TOKEN', HISTORY_HTTP_TOKEN=TOKEN,
                        HISTORY_HTTP_BUDGET_SECONDS='10', HISTORY_HTTP_REQUEST_SECONDS='1',
                        MODE='success', CALL_LOG=str(self.root/'calls'))

    def tearDown(self):
        self.tmp.cleanup()

    def run_body(self, body, **changes):
        env = dict(self.env, **changes)
        start = time.monotonic()
        p = subprocess.run(['bash', '-c', 'set -euo pipefail; source "$1"; '+body,
                            'fixture', str(HELPER)], env=env, capture_output=True, text=True, timeout=6)
        self.assertNotIn(TOKEN, p.stdout+p.stderr)
        return p, time.monotonic()-start

    def test_success_has_bounded_transport_and_no_argv_credentials(self):
        p, _ = self.run_body('history_http_init; history_http_get projects/1/jobs')
        self.assertEqual((p.returncode, p.stdout), (0, 'payload'))

    def test_denied_artifact_discards_partial_and_sensitive_error(self):
        p, _ = self.run_body('history_http_init; history_http_get projects/1/artifacts', MODE='denied')
        self.assertEqual(p.returncode, 22)
        self.assertEqual(p.stdout+p.stderr, '')

    def test_curl_hang_is_bounded(self):
        p, elapsed = self.run_body('history_http_init; history_http_get projects/1/jobs', MODE='hang')
        self.assertEqual(p.returncode, 124)
        self.assertLess(elapsed, 4)

    def test_glab_hang_is_bounded(self):
        p, elapsed = self.run_body('history_http_init; history_http_get projects/1/jobs',
                                  MODE='hang', HISTORY_HTTP_API_ROOT='')
        self.assertEqual(p.returncode, 124)
        self.assertLess(elapsed, 4)

    def test_budget_survives_command_substitutions_and_prevents_later_requests(self):
        p, elapsed = self.run_body('history_http_init; first="$(history_http_get a || true)"; second="$(history_http_get b || true)"; test -z "$first$second"',
                                  MODE='hang', HISTORY_HTTP_BUDGET_SECONDS='1')
        self.assertEqual(p.returncode, 0)
        self.assertLess(elapsed, 4)
        self.assertEqual((self.root/'calls').read_text().splitlines(), ['curl'])

    def test_local_collection_command_obeys_same_deadline(self):
        p, elapsed = self.run_body('history_http_init; history_http_run sleep 10', HISTORY_HTTP_BUDGET_SECONDS='1')
        self.assertEqual(p.returncode, 124)
        self.assertLess(elapsed, 4)

    def test_invalid_budget_and_header_injection_fail_closed(self):
        p, _ = self.run_body('history_http_init', HISTORY_HTTP_BUDGET_SECONDS='0')
        self.assertEqual(p.returncode, 64)
        p, _ = self.run_body('history_http_init; history_http_get a', HISTORY_HTTP_TOKEN='synthetic\nInjected: x')
        self.assertEqual(p.returncode, 64)
        self.assertFalse((self.root/'calls').exists())


if __name__ == '__main__':
    unittest.main()
