#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/phoenix-delivery.yml"
ci_workflow="$repo_root/.github/workflows/phoenix.yml"
deploy_script="$repo_root/scripts/deploy_release_fast.sh"

grep -Fq 'deploy_staging:' "$workflow"
grep -Fq 'needs: deploy_staging' "$workflow"
grep -Fq 'environment:' "$workflow"
grep -Fq 'name: production' "$workflow"
grep -Fq 'needs: deploy_production' "$workflow"
grep -Fq 'scripts/release_tag.sh publish' "$workflow"
grep -Fq '_build/RELEASE_ID' "$ci_workflow"
grep -Fq '_build/VERSION' "$ci_workflow"
grep -Fq 'staging-ssh-known-hosts:' "$workflow"
grep -Fq 'CI_CD_DEPLOY_SSH_KNOWN_HOSTS' "$deploy_script"

printf 'github_phoenix_delivery_contract_test: ok\n'
