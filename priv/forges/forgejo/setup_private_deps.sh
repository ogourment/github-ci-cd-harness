#!/usr/bin/env bash
# Bootstrap for private dependency access.
#
# Consumers with private dependencies keep a copy of this bootstrap and invoke
# it before `mix deps.get`. The harness itself is publicly readable over HTTPS.
set -euo pipefail

install -d -m 0700 "${HOME}/.ssh"

# Install only credentials required by a consumer's remaining private Git deps.
if [[ -n "${FRAMAGIT_DEPLOY_KEY:-}" ]]; then
  printf '%s\n' "${FRAMAGIT_DEPLOY_KEY}" >"${HOME}/.ssh/framagit-ci"
  chmod 0600 "${HOME}/.ssh/framagit-ci"
fi

if [[ -n "${FORGE_DEPS_KEY:-}" ]]; then
  printf '%s\n' "${FORGE_DEPS_KEY}" >"${HOME}/.ssh/forgejo-ci"
  chmod 0600 "${HOME}/.ssh/forgejo-ci"
fi

: "${CI_KNOWN_HOSTS:?CI_KNOWN_HOSTS is required}"
printf '%s\n' "${CI_KNOWN_HOSTS}" >"${HOME}/.ssh/known_hosts"
chmod 0600 "${HOME}/.ssh/known_hosts"

# Hardened hosts set MaxAuthTries 3; pin identities so the right key is offered
# first rather than being cut off behind unrelated agent keys.
cat >"${HOME}/.ssh/config" <<'CONFIG'
Host framagit.org
  IdentityFile ~/.ssh/framagit-ci
  IdentitiesOnly yes
  IdentityAgent none

Host git.agile-u.com
  IdentityFile ~/.ssh/forgejo-ci
  IdentitiesOnly yes
  IdentityAgent none
CONFIG
chmod 0600 "${HOME}/.ssh/config"

mix local.hex --force
mix local.rebar --force

# Framagit rate-limits SSH and every job in the workflow fetches
# acceptance_harness from it, so a healthy build fails intermittently with
# kex_exchange_identification. Retry with backoff. Mirroring the private
# dependencies onto Forgejo would remove this dependency entirely.
for attempt in 1 2 3 4 5; do
  if mix deps.get; then
    break
  fi
  if [ "$attempt" -eq 5 ]; then
    echo "mix deps.get failed after 5 attempts" >&2
    exit 1
  fi
  sleep $((attempt * 10))
done
