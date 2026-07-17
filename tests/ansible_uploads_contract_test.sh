#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_role="${root}/ansible/roles/phoenix_blue_green"
web_role="${root}/ansible/roles/web"

grep -q 'phoenix_uploads_dir: ""' "${runtime_role}/defaults/main.yml"
grep -q 'phoenix_uploads_env_var: ""' "${runtime_role}/defaults/main.yml"
grep -q 'Ensure shared uploads directory exists' "${runtime_role}/tasks/main.yml"
grep -q '{{ phoenix_uploads_env_var }}="{{ phoenix_uploads_dir }}"' \
  "${runtime_role}/templates/phoenix.env.j2"

grep -q 'nginx_uploads_dir: ""' "${web_role}/defaults/main.yml"
grep -q 'nginx_uploads_url_prefix: ""' "${web_role}/defaults/main.yml"
grep -q 'location \^~ {{ nginx_uploads_url_prefix }}/' "${web_role}/templates/app.nginx.j2"
grep -q 'limit_except GET HEAD { deny all; }' "${web_role}/templates/app.nginx.j2"

printf 'ansible uploads contract: ok\n'
