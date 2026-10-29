#!/usr/bin/env python3
"""An exact, expiring approval on main; never trust a branch's approval file."""
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request


def require(condition, message):
    if not condition:
        raise ValueError(message)


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def git(*args):
    return subprocess.check_output(['git', *args])


def validate(approval, run, repository, workflow, now=None):
    require(approval.get('purpose') == 'security-only', 'Not a security-only approval')
    for field in ('sha', 'base_sha'):
        require(re.fullmatch(r'[0-9a-f]{40}', approval.get(field, '')), 'Invalid approved SHA')
    require(re.fullmatch(r'[0-9a-f]{64}', approval.get('diff_sha256', '')), 'Invalid approved diff digest')
    require(run['repository']['full_name'] == repository and run['path'] == workflow, 'Wrong approved repository/workflow')
    require(run['event'] == 'workflow_dispatch', 'Hotfix requires explicit dispatch')
    require(run['head_sha'] == approval['sha'], 'Unapproved hotfix commit')
    require(run['head_branch'] == approval.get('branch') and run['head_branch'].startswith('security/'), 'Unapproved hotfix branch')
    expiry = datetime.fromisoformat(approval['expires_at'].replace('Z', '+00:00'))
    require(expiry.tzinfo is not None and expiry > (now or datetime.now(timezone.utc)), 'Hotfix approval expired')
    expected = approval['production_base']
    require(re.fullmatch(r'[1-9][0-9]*', expected.get('pipeline_id', '')), 'Invalid production pipeline ID')
    require(all(isinstance(expected.get(k), str) and expected[k] for k in ('version', 'release_id', 'pipeline_id')), 'Incomplete production base identity')


def authorize(run, repository, workflow, policy_path, request=api):
    require(re.fullmatch(r'\.github/[A-Za-z0-9_./-]+\.json', policy_path or '') and '..' not in policy_path, 'Hotfix policy is disabled or invalid')
    main_sha = request(f'repos/{repository}/git/ref/heads/main')['object']['sha']
    document = request(f'repos/{repository}/contents/{policy_path}?ref={main_sha}')
    require(document.get('type') == 'file' and document.get('encoding') == 'base64', 'Invalid main approval document')
    policy = json.loads(base64.b64decode(document['content'], validate=False))
    require(policy.get('schema') == 1, 'Unsupported hotfix policy')
    matches = [a for a in policy['approvals'] if a.get('sha') == run['head_sha']]
    require(len(matches) == 1, 'Missing or duplicate hotfix approval on main')
    approval = matches[0]
    validate(approval, run, repository, workflow)
    git('fetch', '--no-tags', 'origin', approval['sha'], approval['base_sha'])
    require(subprocess.run(['git', 'merge-base', '--is-ancestor', approval['base_sha'], approval['sha']], check=False).returncode == 0, 'Hotfix is not based on approved production source')
    diff = git('diff', '--binary', approval['base_sha'], approval['sha'])
    require(hashlib.sha256(diff).hexdigest() == approval['diff_sha256'], 'Hotfix differs from approved patch')
    names = git('diff', '--name-only', approval['base_sha'], approval['sha']).decode().splitlines()
    require(not any('/migrations/' in '/' + n for n in names), 'Security-only lane forbids migrations')
    versions = []
    for sha in (approval['base_sha'], approval['sha']):
        source = git('show', f'{sha}:mix.exs').decode()
        match = re.search(r'(?:version:|@version)\s*"(\d+)\.(\d+)\.(\d+)"', source)
        require(match is not None, 'Cannot verify application patch version')
        versions.append(tuple(map(int, match.groups())))
    require('.'.join(map(str, versions[0])) == approval['production_base']['version'], 'Production base version differs from source')
    require(versions[0][:2] == versions[1][:2] and versions[1][2] > versions[0][2], 'Security-only lane requires a PATCH version')
    base = request(f"repos/{repository}/actions/runs/{approval['production_base']['pipeline_id']}")
    require(base['head_sha'] == approval['base_sha'] and base['conclusion'] == 'success', 'Production base source is unverified')
    return approval


def check_production(url, expected):
    with urllib.request.urlopen(url, timeout=20) as response:
        actual = json.load(response)
    require(actual.get('status') == 'ok' and actual.get('database') == 'ok', 'Production base is unhealthy')
    require(all(str(actual.get(k)) == v for k, v in expected.items()), 'Production moved since hotfix approval; reconcile before deployment')


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'production-base':
        check_production(os.environ['PRODUCTION_HEALTH_URL'], json.loads(os.environ['EXPECTED_PRODUCTION_BASE']))
        return
    if os.environ['GITHUB_REF'] == 'refs/heads/main':
        return
    repository = os.environ['GITHUB_REPOSITORY']
    run = api(f"repos/{repository}/actions/runs/{os.environ['GITHUB_RUN_ID']}")
    authorize(run, repository, os.environ.get('SOURCE_WORKFLOW', '.github/workflows/ci.yml'), os.environ.get('SECURITY_HOTFIX_POLICY', ''))
    print('Exact security-only hotfix source approved on main')


if __name__ == '__main__':
    try:
        main()
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'Security hotfix refused: {error}')
