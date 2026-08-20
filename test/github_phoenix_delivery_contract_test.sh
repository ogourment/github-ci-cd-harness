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
grep -Fq 'tar -C _build/prod/rel -czf _build/release.tar.gz .' "$ci_workflow"
[[ "$(grep -Fc 'tar -C _build/prod/rel -xzf _build/release.tar.gz' "$workflow")" -eq 2 ]]
grep -Fq 'run: ${{ inputs.test-command }}' "$ci_workflow"
grep -Fq 'staging-ssh-known-hosts:' "$workflow"
grep -Fq 'CI_CD_DEPLOY_SSH_KNOWN_HOSTS' "$deploy_script"

printf 'github_phoenix_delivery_contract_test: ok\n'
