#!/usr/bin/env bash
# Source this provider seam; GitLab already supplies the normalized fields.
ci_cd_load_metadata() {
  local metadata_file source_pipeline_id source_pipeline_url source_created_at
  if [[ -z "${GITHUB_RUN_ID:-}" || "${GITHUB_SERVER_URL:-}" == "https://github.com" ]]; then
    return 0
  fi
  if [[ -z "${FORGEJO_TOKEN:-}" ]]; then
    echo "CI metadata: supply the temporary Forgejo workflow token for job identity and pipeline timing" >&2
    return 0
  fi
  metadata_file="$(mktemp)" || return 0
  source_pipeline_id="${CI_PIPELINE_ID:-}"
  source_pipeline_url="${CI_PIPELINE_URL:-}"
  source_created_at="${CI_PIPELINE_CREATED_AT:-}"
  if python3 "$(dirname "${BASH_SOURCE[0]}")/../forges/forgejo/ci_metadata.py" --env-file "$metadata_file" --shell; then
    # Only validated identities, URLs and ISO timestamps are written; no token.
    source "$metadata_file"
    # Promotion can deliberately preserve the staged artifact's source run.
    # Execution/job identity must never overwrite that deployed identity.
    if [[ -n "$source_pipeline_id" && "$source_pipeline_id" != "$CI_CD_EXECUTION_RUN_ID" ]]; then
      export CI_PIPELINE_ID="$source_pipeline_id"
      export CI_PIPELINE_URL="$source_pipeline_url"
      if [[ -n "$source_created_at" ]]; then
        export CI_PIPELINE_CREATED_AT="$source_created_at"
      else
        unset CI_PIPELINE_CREATED_AT
      fi
    fi
    if [[ "${ACCEPTANCE_REPORT_URL:-}" == "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" ]]; then
      export ACCEPTANCE_REPORT_URL="$CI_PIPELINE_URL"
    fi
  fi
  rm -f "$metadata_file"
  return 0
}
ci_cd_load_metadata
unset -f ci_cd_load_metadata
