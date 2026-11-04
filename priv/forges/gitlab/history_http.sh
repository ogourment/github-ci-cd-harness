#!/usr/bin/env bash
# Source this helper. Optional historical reporting must not block CI quality.
# Absolute exported deadline survives command substitutions and nested shells.
history_http_init() {
  local budget="${HISTORY_HTTP_BUDGET_SECONDS:-120}"
  local request="${HISTORY_HTTP_REQUEST_SECONDS:-15}"
  for value in "$budget" "$request"; do
    [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 && "$value" -le 300 ]] || return 64
  done
  HISTORY_HTTP_REQUEST_SECONDS="$request"
  HISTORY_HTTP_DEADLINE=$(( $(date +%s) + budget ))
  export HISTORY_HTTP_REQUEST_SECONDS HISTORY_HTTP_DEADLINE
}

history_http_remaining() {
  local remaining=$(( HISTORY_HTTP_DEADLINE - $(date +%s) ))
  [[ "$remaining" -gt 0 ]] || return 124
  printf '%s' "$remaining"
}

history_http_run() {
  local remaining
  remaining="$(history_http_remaining)" || return 124
  timeout --kill-after=2 "$remaining" "$@"
}

history_http_get() {
  local path="$1" remaining request payload status
  remaining="$(history_http_remaining)" || return 124
  request="$HISTORY_HTTP_REQUEST_SECONDS"
  [[ "$remaining" -ge "$request" ]] || request="$remaining"

  if [[ -n "${HISTORY_HTTP_API_ROOT:-}" ]]; then
    local header="${HISTORY_HTTP_AUTH_HEADER:-}" token="${HISTORY_HTTP_TOKEN:-}"
    # Reject header injection, keep credentials out of argv/files, and never
    # forward authentication on HTTP redirects. Unavailable history is optional.
    case "$header" in PRIVATE-TOKEN|JOB-TOKEN|'') ;; *) return 64 ;; esac
    [[ "$token" != *$'\r'* && "$token" != *$'\n'* ]] || return 64
    if payload="$(
      { if [[ -n "$header" && -n "$token" ]]; then printf '%s: %s\n' "$header" "$token"; fi; } |
        timeout --kill-after=2 "$request" curl --fail --silent --show-error \
          --location --max-redirs 0 --retry 0 --connect-timeout 5 \
          --max-time "$request" --max-filesize 16777216 --header @- \
          "${HISTORY_HTTP_API_ROOT}/${path}" 2>/dev/null
    )"; then
      printf '%s' "$payload"
    else
      status=$?
      return "$status"
    fi
  else
    if payload="$(timeout --kill-after=2 "$request" glab api "$path" 2>/dev/null)"; then
      printf '%s' "$payload"
    else
      status=$?
      return "$status"
    fi
  fi
}
