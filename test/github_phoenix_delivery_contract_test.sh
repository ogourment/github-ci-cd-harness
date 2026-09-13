#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/phoenix-delivery.yml"
ci_workflow="$repo_root/.github/workflows/phoenix.yml"
deploy_script="$repo_root/priv/core/deploy_release_fast.sh"

grep -Fq 'deploy_staging:' "$workflow"
grep -Fq 'needs: deploy_staging' "$workflow"
grep -Fq 'environment:' "$workflow"
grep -Fq 'name: production' "$workflow"
grep -Fq 'needs: deploy_production' "$workflow"
grep -Fq 'priv/core/release_tag.sh publish' "$workflow"
grep -Fq 'bash .ci-cd-harness/priv/core/staging_release_smoke.sh' "$workflow"
grep -Fq '_build/RELEASE_ID' "$ci_workflow"
grep -Fq '_build/VERSION' "$ci_workflow"
grep -Fq 'Package verified acceptance evidence with the exact release' "$ci_workflow"
grep -Fq 'priv/acceptance_evidence' "$ci_workflow"
grep -Fq 'inputs.build-release && inputs.run-acceptance' "$ci_workflow"
grep -Fq 'tar -C _build/prod/rel -czf _build/release.tar.gz .' "$ci_workflow"
[[ "$(grep -Fc 'tar -C _build/prod/rel -xzf _build/release.tar.gz' "$workflow")" -eq 2 ]]
grep -Fq 'run: ${{ inputs.test-command }}' "$ci_workflow"
[[ "$(grep -Fc 'retention-days: 14' "$ci_workflow")" -eq 2 ]]
grep -Fq 'staging-ssh-known-hosts:' "$workflow"
grep -Fq 'CI_CD_DEPLOY_SSH_KNOWN_HOSTS' "$deploy_script"

promotion="$repo_root/.github/workflows/phoenix-promote-production.yml"
grep -Fq 'name: production' "$promotion"
grep -Fq 'actions: read' "$promotion"
grep -Fq 'run-id: ${{ inputs.source-run-id }}' "$promotion"
grep -Fq 'priv/forges/github/verify_promotion.py' "$promotion"
grep -Fq 'priv/core/release_tag.sh preflight' "$promotion"
grep -Fq 'priv/core/deploy_release_fast.sh production' "$promotion"
grep -Fq 'priv/core/release_tag.sh publish' "$promotion"
! grep -Eq 'mix |deploy_release_fast.sh staging|needs: deploy_staging' "$promotion"

python3 - "$repo_root" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
for path in [*root.glob('.github/workflows/*.yml'), *root.glob('templates/github/*.yml')]:
    assert isinstance(yaml.safe_load(path.read_text()), dict), path
workflow = yaml.safe_load((root / '.github/workflows/phoenix-promote-production.yml').read_text())
steps = workflow['jobs']['promote_production']['steps']
runs = [s.get('run', '') for s in steps]
def index(fragment):
    return next(i for i, command in enumerate(runs) if fragment in command)
assert index('verify_promotion.py') < index('release_tag.sh preflight') < index('deploy_release_fast.sh production') < index('release_tag.sh publish')
stage = yaml.safe_load((root / '.github/workflows/phoenix-delivery.yml').read_text())['jobs']['deploy_staging']['steps']
assert next(i for i, s in enumerate(stage) if 'staging_release_smoke.sh' in s.get('run', '')) < next(i for i, s in enumerate(stage) if 'staging_receipt.py' in s.get('run', ''))
PY

printf 'github_phoenix_delivery_contract_test: ok\n'
