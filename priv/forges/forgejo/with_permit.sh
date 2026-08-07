#!/usr/bin/env bash
# Runs a command under the shared CI permit broker, using the Forgejo run's own
# creation time as the queue position so a job that has waited longer is
# admitted first.
#
# Requires the broker socket and the ci-with-permit shim to be mounted into the
# job container. Forge-specific only in how the run identity is discovered.
set -euo pipefail

: "${FORGEJO_TOKEN:?FORGEJO_TOKEN is required}"
: "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_JOB:?GITHUB_JOB is required}"

created_at="$({
  curl --fail --silent --show-error \
    --header "Authorization: token ${FORGEJO_TOKEN}" \
    "${GITHUB_SERVER_URL}/api/v1/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
} | sed -n 's/.*"created":"\([^"]*\)".*/\1/p')"

if [[ -z "${created_at}" ]]; then
  echo "Forgejo run did not provide its creation time" >&2
  exit 1
fi

export CI_PERMIT_PENDING_SINCE
CI_PERMIT_PENDING_SINCE="$(date -d "${created_at}" +%s)"
export CI_PERMIT_PROVIDER=forgejo
export CI_PERMIT_REQUEST_ID="forgejo:${GITHUB_REPOSITORY}:${GITHUB_RUN_ID}:${GITHUB_JOB}"

exec ci-with-permit "$@"
