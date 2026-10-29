"""Exact-source approval, production ancestry and stale-base admission regressions."""
import base64
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'priv/forges/github'))
import security_hotfix as hotfix


class HotfixTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.previous)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.base = self.commit('version: "1.2.3"\n')
        self.sha = self.commit('version: "1.2.4"\n')
        self.git('remote', 'add', 'origin', str(self.root))
        self.run = dict(repository=dict(full_name='owner/app'), path='.github/workflows/ci.yml', head_branch='security/fix', head_sha=self.sha, event='workflow_dispatch')
        self.approval = dict(purpose='security-only', sha=self.sha, base_sha=self.base, branch='security/fix', diff_sha256=hashlib.sha256(hotfix.git('diff', '--binary', self.base, self.sha)).hexdigest(), expires_at=(datetime.now(timezone.utc) + timedelta(days=1)).isoformat(), production_base=dict(version='1.2.3', release_id='app-1.2.3-42', pipeline_id='42'))
        self.requested = []

    def git(self, *args):
        return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL).decode().strip()

    def commit(self, source):
        Path('mix.exs').write_text(source)
        self.git('add', '.')
        self.git('commit', '-qm', 'Fixture')
        return self.git('rev-parse', 'HEAD')

    def request(self, path):
        self.requested.append(path)
        if '/git/ref/' in path:
            return dict(object=dict(sha='f' * 40))
        if '/contents/' in path:
            return dict(type='file', encoding='base64', content=base64.b64encode(json.dumps(dict(schema=1, approvals=[self.approval])).encode()).decode())
        return dict(head_sha=self.base, conclusion='success')

    def authorize(self):
        return hotfix.authorize(self.run, 'owner/app', '.github/workflows/ci.yml', '.github/security-hotfixes.json', self.request)

    def test_exact_patch_is_approved_from_immutable_main_revision(self):
        self.assertEqual(self.authorize()['sha'], self.sha)
        self.assertIn('?ref=' + 'f' * 40, self.requested[1])

    def test_default_and_traversal_policies_are_disabled(self):
        for path in ('', '../approval.json', '.github/../approval.json'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                hotfix.authorize(self.run, 'owner/app', self.run['path'], path, self.request)

    def test_other_sha_branch_workflow_repository_event_or_expired_approval_is_denied(self):
        original = copy.deepcopy(self.run)
        for change in (dict(head_sha='a'*40), dict(head_branch='feature'), dict(path='other.yml'), dict(repository=dict(full_name='other/app')), dict(event='pull_request')):
            self.run = dict(original, **change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.authorize()
        self.run = original
        self.approval['expires_at'] = '2020-01-01T00:00:00Z'
        with self.assertRaises(ValueError):
            self.authorize()

    def test_tampered_diff_is_denied(self):
        self.approval['diff_sha256'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'approved patch'):
            self.authorize()

    def test_unrelated_base_is_denied(self):
        self.git('checkout', '--orphan', 'unrelated')
        self.approval['base_sha'] = self.commit('version: "1.2.3"\n# unrelated root\n')
        with self.assertRaisesRegex(ValueError, 'based on approved'):
            self.authorize()

    def test_minor_release_and_migration_are_denied_even_if_digest_is_approved(self):
        for source, migration in [('version: "1.3.0"\n', False), ('version: "1.2.5"\n', True)]:
            if migration:
                Path('priv/repo/migrations').mkdir(parents=True)
                Path('priv/repo/migrations/fixture.exs').write_text('migration')
            self.run['head_sha'] = self.approval['sha'] = self.commit(source)
            self.approval['diff_sha256'] = hashlib.sha256(hotfix.git('diff', '--binary', self.base, self.approval['sha'])).hexdigest()
            with self.subTest(migration=migration), self.assertRaises(ValueError):
                self.authorize()

    def test_changed_production_base_is_denied(self):
        expected = self.approval['production_base']
        for actual, accepted in [(dict(expected, status='ok', database='ok'), True), (dict(expected, version='1.2.4', status='ok', database='ok'), False), (dict(expected, status='error', database='ok'), False)]:
            import io
            with self.subTest(actual=actual), patch.object(hotfix.urllib.request, 'urlopen', return_value=io.BytesIO(json.dumps(actual).encode())):
                if accepted:
                    hotfix.check_production('https://fixture.invalid/health', expected)
                else:
                    with self.assertRaises(ValueError):
                        hotfix.check_production('https://fixture.invalid/health', expected)


if __name__ == '__main__':
    unittest.main()
