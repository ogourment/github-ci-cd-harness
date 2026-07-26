# nginx passive failover between blue/green Phoenix instances

Status: **planned, not implemented.** Decision recorded 2026-07-26 against
`main` @ `ce6621e`. No code in this repository has changed yet.

## 1. Background

Q: how easy is it to configure nginx for automatic failover between two
(blue/green) app (elixir phoenix) instances on the same box?

A: Mechanically, it is easy. NGINX can treat one Phoenix instance as primary and
the other as a backup, both listening on different loopback ports. The more
difficult parts are WebSocket behavior, application state, health-check
semantics, and database compatibility during deployments.

A basic active/passive configuration:

```nginx
# Inside the http {} block
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

upstream phoenix_app {
    # Blue: normally receives all new connections
    server 127.0.0.1:4000 max_fails=1 fail_timeout=5s;

    # Green: used when blue is unavailable
    server 127.0.0.1:4001 backup;

    keepalive 32;
}

server {
    listen 443 ssl;
    server_name app.example.com;

    # TLS configuration omitted

    location / {
        proxy_pass http://phoenix_app;
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Phoenix Channels / LiveView WebSockets
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_connect_timeout 1s;
        proxy_read_timeout 75s;

        proxy_next_upstream error timeout invalid_header
                            http_502 http_503 http_504;
        proxy_next_upstream_tries 2;
    }
}
```

NGINX's `backup` parameter sends traffic to that server only when the primary
servers are unavailable. In open-source NGINX, `max_fails` and `fail_timeout`
provide passive failure detection: failures observed while handling real traffic
temporarily mark the server unavailable. ([Nginx][1])

The important limitation is that this is not continuous health checking. When
blue fails, a request may first encounter blue's connection failure and then be
retried against green. After `fail_timeout`, NGINX will periodically try blue
again. Periodic active health checks using a dedicated endpoint such as
`/healthz` are built into NGINX Plus, not standard open-source NGINX.
([Nginx][2])

WebSockets require the explicit HTTP/1.1 upgrade headers shown above. An
already-established WebSocket cannot be moved from blue to green: it disconnects
and the client must reconnect. ([Nginx][3]) For Phoenix LiveView, the client
automatically reconnects with exponential backoff, and the new connection can be
routed to the surviving instance. However, process-local LiveView state may be
lost unless it can be reconstructed from parameters, sessions, or persistent
storage. ([Hexdocs][4])

There is also an important retry-safety constraint. By default, NGINX does not
retry non-idempotent requests such as `POST` or `PATCH` after they have already
been sent upstream. Enabling `non_idempotent` retries can duplicate writes, so it
should generally remain disabled unless the application implements idempotency
keys or equivalent protection. NGINX also cannot switch servers after part of the
response has already reached the client. ([Nginx][5])

Assessment of the generic approach:

* **Basic automatic process failover:** easy.
* **Reliable failover for normal HTTP traffic:** straightforward.
* **Seamless failover for existing WebSockets:** impossible; reconnect is required.
* **Application-aware active health checks with NGINX OSS:** requires an external monitor or a different proxy.
* **Protection against the entire machine failing:** none, because both instances and NGINX share the same host.

## 2. Why this does not drop into this repository as written

The design above assumes **both instances are running**. This repository's
blue/green deliberately stops the idle one.

| Location | Behavior |
| --- | --- |
| `ansible/roles/phoenix_blue_green/templates/phoenix_deploy.sh.j2:262-266` | After cutover, drains `deploy_drain_sec` then `systemctl stop` the old color |
| `ansible/roles/phoenix_blue_green/templates/phoenix_rollback.sh.j2:72-73` | Same, in reverse |
| `ansible/roles/phoenix_blue_green/tasks/main.yml:128-134` | On provision, starts only colors that have a release |
| `ansible/roles/phoenix_blue_green/tasks/main.yml:89-99` | Seeds a single-server upstream include |

Adding `server 127.0.0.1:4001 backup;` today would point at a closed socket in
steady state. nginx would fail over to it, burn a `proxy_next_upstream` try, and
return 502 anyway. The feature would be inert — worse than absent, because it
looks like coverage.

Making it real means keeping the previous color running, which is a genuine
behavior change with consequences the generic write-up does not cover:

1. **Two releases against one database.** Migration backward-compatibility stops
   being a one-deploy constraint and becomes a standing one for as long as both
   are up.
2. **Duplicate scheduled work.** Oban/Quantum/GenServer singletons in the old
   release keep firing. For any consumer running background jobs this is a
   correctness bug, not just a resource cost.
3. **Failover silently serves stale code.** Often the right call — the likeliest
   reason the live color died is the release just shipped — but nothing tells an
   operator they are being served N-1.
4. **`max_fails=1 fail_timeout=5s` re-probes the dead primary with real traffic
   every 5s.** During a restart, users alternate between the two releases
   request-by-request.

### Two corrections to the generic config

* **`keepalive 32` is dead weight as written.** The map sends `Connection: close`
  for non-WebSocket requests, defeating the keepalive pool it just declared. The
  websocket-plus-keepalive form maps `'' → ''`, not `close`.
* **`http_503` in `proxy_next_upstream` is unsafe here.** A Phoenix app returning
  503 while booting, or from a deliberate maintenance path, would be retried
  against the previous release instead of surfacing that state. Drop
  `http_502`/`http_503`/`http_504`; the default `error timeout` already covers
  the connection-refused case that standby exists for.

### A pre-existing bug found while reviewing

`ansible/roles/web/templates/app.nginx.j2:29` and `:136` hardcode
`proxy_set_header Connection "upgrade"` on **every** proxied request, including
plain HTTP. The `map $http_upgrade` construct is the correct fix and is worth
landing regardless of which failover option is chosen.

## 3. Decision

**Bounded standby window.** After a cutover, the previous color keeps running for
a configurable number of seconds registered as the nginx `backup` upstream, then
a transient systemd timer retires it.

This covers the risk that actually matters — the fresh release dying moments
after going live — while bounding the dual-schema and duplicate-scheduler
exposure to that window instead of making it permanent.

Rejected alternatives:

* **Permanent hot standby** — real continuous failover, but permanent duplicate
  background jobs and a permanent two-release schema constraint. Only safe for
  consumers with no scheduled work; too sharp an edge for a shared harness
  default.
* **Proxy hardening only** — no new risk, but leaves the 502-until-someone-
  notices window that prompted the question.

Default is `deploy_standby_sec: 0`, which preserves today's behavior exactly.
Consumers opt in per app.

## 4. Implementation plan

Progress: 0/19 — 16 implementation items, 3 host verification items.

### Step 1 — `web` role: proxy hardening (independent, land first)

- [ ] Add the new defaults to `ansible/roles/web/defaults/main.yml`
- [ ] Add the `map` block above the first `server {}` in `app.nginx.j2`
- [ ] Update **both** `location /` blocks (lines 21-30 and 128-137)

New defaults in `ansible/roles/web/defaults/main.yml`:

```yaml
# nginx variables are global to http {}, so each site needs its own name or a
# second app on the box makes the map a duplicate-declaration error.
nginx_connection_upgrade_var: "{{ app_name | replace('-', '_') }}_connection_upgrade"

nginx_proxy_next_upstream: "error timeout invalid_header"
nginx_proxy_next_upstream_tries: 2
nginx_proxy_connect_timeout: "2s"
nginx_proxy_read_timeout: "75s"
nginx_proxy_send_timeout: "75s"
```

In `app.nginx.j2`, add the map above the first `server {}` block. Debian includes
`sites-enabled/*` from inside `http {}`, so this is the correct level — no new
`conf.d` file needed:

```nginx
map $http_upgrade ${{ nginx_connection_upgrade_var }} {
    default upgrade;
    ''      '';
}
```

Then in **both** `location /` blocks (lines 21-30 and 128-137), replace
`Connection "upgrade"` with `Connection ${{ nginx_connection_upgrade_var }}` and
add the timeout and `proxy_next_upstream` directives.

### Step 2 — `phoenix_blue_green` role: new defaults

- [ ] Add the four new defaults, with the duplicate-scheduled-work hazard
      documented in the comment above `deploy_standby_sec`

```yaml
deploy_standby_sec: 0
deploy_standby_end_script: "/usr/local/bin/{{ app_name }}_standby_end"
nginx_upstream_max_fails: 1
nginx_upstream_fail_timeout: "5s"
```

### Step 3 — new `phoenix_standby_end.sh.j2` template

- [ ] Write the template
- [ ] Install it from `tasks/main.yml` alongside the deploy and rollback
      scripts (`mode: "0755"`, root-owned)

Installed at `deploy_standby_end_script`. Re-reads `current_color` rather than
taking the color as an argument, so a rollback or a second deploy during the
window cannot let a stale timer stop whichever instance is actually serving.

Order matters: rewrite the upstream to live-only and reload **before**
`systemctl stop` on the standby, so no request is failed over to a port that is
already closing.

### Step 4 — `phoenix_deploy.sh.j2`

- [ ] Add the `write_upstream` helper and use it at both existing rewrite sites
- [ ] Retire any existing standby before staging (gated on `STANDBY_SEC > 0`)
- [ ] Replace drain-then-stop at cutover with backup-upstream plus scheduled
      retirement (gated on `STANDBY_SEC > 0`)

Add a `write_upstream <live_port> [standby_port]` helper; with two ports it
emits the live server with `max_fails`/`fail_timeout` plus a `backup` line, with
one port it emits today's single-server form. Use it at both existing rewrite
sites.

Two behavior changes, both gated on `STANDBY_SEC > 0`:

* **Before staging** (after the `SRC_DIR` check at line 149): cancel any pending
  `{{ app_name }}-standby-end` timer, `systemctl reset-failed` it, then invoke
  the standby-end script. The target color may still be up as the previous
  deploy's standby; retiring it here means its release directory is not rewritten
  underneath a running BEAM, and means the health check remains the first thing
  that ever sends traffic to the new release. Without this, a hiccup on the live
  color during the health-check phase would route real users onto an
  un-health-checked release — exactly what blue/green exists to prevent.
* **At cutover** (line 262-266): instead of drain-then-stop, write the upstream
  with the old color as `backup`, then schedule the retirement:

  ```bash
  systemd-run --unit="${STANDBY_UNIT}" --on-active="${STANDBY_SEC}" \
    "${STANDBY_END_SCRIPT}"
  ```

  Do not block the deploy for `STANDBY_SEC` — a 300s standby would stall the CI
  pipeline for its full duration.

### Step 5 — `phoenix_rollback.sh.j2`

- [ ] Cancel a pending standby timer at the start of rollback

Rollback runs *because* the live color is bad, so keeping a known-bad release as
the failover target is wrong. It should keep writing a single-server upstream —
that logic is already correct. The only change needed is cancelling a pending
standby timer at the start, so it cannot fire mid-rollback.

### Step 6 — tests and docs

- [ ] New `tests/ansible_blue_green_failover_contract_test.sh`, following the
      grep-based style of `tests/ansible_uploads_contract_test.sh`. Assert: the
      map is present and maps `''` to empty rather than `close`;
      `proxy_next_upstream` excludes `http_503`; `deploy_standby_sec` defaults
      to `0`; the standby-end script drops the backup before stopping; deploy
      cancels the timer before restaging.
- [ ] Wire it into `.gitlab-ci.yml` `template_smoke` — both the `bash -n` list
      on lines 33-34 and the execution list on lines 35-40
- [ ] Wire the **existing** `tests/ansible_uploads_contract_test.sh` into CI
      too; it is currently not run despite the README telling consumers to run
      it
- [ ] README: document `deploy_standby_sec` near the uploads-contract
      paragraph (lines 37-43), leading with the duplicate-background-work
      constraint rather than the failover benefit
- [ ] README: state the residual limitations from section 5
- [ ] Bump `VERSION` (0.6.22 → 0.7.0; the vhost template change affects every
      consumer on re-provision) and update the `ref:` examples in the README

### Verification before release

- [ ] Both instances answer independently during the standby window
- [ ] Killing the live color mid-standby fails over to the standby
- [ ] `nginx -t` passes with two apps on one box (checks the per-site map
      variable name)

Ansible templates are not exercised by CI beyond grep assertions, so verify on a
real host:

```bash
# Both instances answer independently during the standby window
curl -f http://127.0.0.1:4000/health
curl -f http://127.0.0.1:4001/health

# Observe the interruption while hitting the live color
while true; do
  curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://app.example.com/health
  sleep 0.25
done

# In another terminal, kill the live color mid-standby
sudo systemctl stop myapp@blue
```

Expect a small number of failed requests, then 200s served by the standby.
Confirm `nginx -t` passes with two apps on one box (the per-site map variable
name is the thing being checked).

## 5. Residual limitations

Unchanged by this plan, and worth stating in the README so nobody assumes
otherwise:

* Established WebSocket/LiveView connections drop on failover and must reconnect.
* There are no active health checks; detection is passive and costs the request
  that discovers the failure.
* Nothing here survives the box itself failing.
* Outside the standby window, behavior is exactly as today — a single-server
  upstream with no failover target.

[1]: https://nginx.org/en/docs/http/ngx_http_upstream_module.html "Module ngx_http_upstream_module"
[2]: https://nginx.org/en/docs/http/ngx_http_upstream_hc_module.html "Module ngx_http_upstream_hc_module"
[3]: https://nginx.org/en/docs/http/websocket.html "WebSocket proxying"
[4]: https://hexdocs.pm/phoenix_live_view/deployments.html "Deployments and recovery — Phoenix LiveView"
[5]: https://nginx.org/en/docs/http/ngx_http_proxy_module.html "Module ngx_http_proxy_module - nginx"
