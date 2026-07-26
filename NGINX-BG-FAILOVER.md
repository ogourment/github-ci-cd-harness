# Plan: bounded same-host failover for blue/green Phoenix

Status: **implemented; live failover validation remaining.**

## Goal

Make blue/green production deploys survive two common failures without adding
another host:

1. reject a new release that starts but cannot serve a real production page;
2. temporarily fail over to the previous color if the new Phoenix process or
   port fails shortly after deployment.

This is a practical first step toward high availability. It improves release
resilience on one host; it is not host-level HA.

## Why this is needed

A release can pass staging acceptance and still fail only in production. One
observed class of failure is runtime code depending on a build tool that exists
in staging but is deliberately absent from the production release. The Phoenix
process starts and its health endpoint passes, while real pages return HTTP 500.

The existing direct readiness check could pass because the BEAM, endpoint, and
database were healthy. NGINX passive failover would not help either: HTTP 500
is a valid upstream response, not a connection failure.

The deployment contract therefore needs three distinct checks:

- **Liveness:** the Phoenix process responds through a cheap application route.
- **Readiness:** the release identity and required dependencies are correct.
- **Synthetic smoke:** a public request through TLS and NGINX renders a
  representative production page as HTML.

Endpoint names are not standardized by this plan. `/health`, `/health/deep`,
`/api/health/live`, and `/api/health/ready` are all valid names when their
configured behavior satisfies the contract.

## Contract and ownership

The application owns application semantics. The harness owns deployment
orchestration and contract validation.

### Consumer application responsibilities

- Implement an unauthenticated readiness endpoint. A route such as
  `/health/deep` is application code supplied and tested by the consumer, not
  by this repository.
- Return 2xx JSON only when the release is ready for traffic. Return non-2xx,
  normally 503, when a required database, schema, queue, or other
  application-defined dependency is unavailable.
- Include `version`, `release_id`, `pipeline_id`, and `color` in every
  successful readiness response:

  ```json
  {
    "status": "ready",
    "version": "1.2.3",
    "release_id": "v1.2.3-abcdef12-1234",
    "pipeline_id": "1234",
    "color": "blue"
  }
  ```

- The `status` value and additional fields are consumer-defined. HTTP status is
  authoritative; the harness validates the four identity fields above.
- Source identity from the environment written into the deployed slot. Do not
  infer mutable host state or depend on development/build tools at runtime.
- Keep a liveness endpoint cheap and independent of optional external services
  when the application exposes one. Liveness is useful for process monitoring;
  readiness is the deploy gate.
- Configure a stable, unauthenticated HTML smoke path that exercises a real
  production rendering path. A JSON health route is not a synthetic smoke.
- Test the readiness success and failure cases, identity fields, HTTP statuses,
  and smoke path in the application repository.
- Confirm that migrations are backward-compatible and that running both colors
  during the selected standby window cannot duplicate unsafe scheduled or
  singleton work.

### Harness responsibilities

- Accept consumer-configured readiness and public smoke paths without assigning
  application-specific meaning to their names.
- Inject expected release, pipeline, and color identity into the target slot.
- Verify readiness directly on the candidate loopback port before cutover.
- Verify the same identity through public HTTPS after NGINX cutover, then verify
  the public HTML smoke path.
- Reject missing fields, identity mismatches, non-2xx responses, wrong content
  types, timeouts, and connection failures.
- Own NGINX upstream generation, reload validation, standby scheduling,
  cutover commit/abort behavior, and generic contract tests.
- Never implement or guess consumer dependency checks. A database-only default
  would be incorrect for applications whose readiness also depends on queues,
  storage, migrations, or another required service.

## Decisions and boundaries

- Keep the previous color as an NGINX `backup` for a bounded standby window.
- Default `deploy_standby_sec` to `0`; consumers opt in after checking that
  running two releases briefly is safe. Recommend `300` seconds initially.
- A cutover is not committed until the public identity check and synthetic
  smoke both pass through NGINX.
- If post-cutover verification fails, abort the cutover: restore the prior
  color as the sole upstream, stop the candidate, fail the deployment, and fix
  forward with a new release.
- Never reverse migrations, delete the candidate release, or run the rollback
  script automatically. Database migrations must remain backward-compatible
  with the previous color for the standby window.
- Keep NGINX retry policy at connection and timeout failures. Do not retry
  generic HTTP 500/502/503/504 responses; doing so can mask application errors
  and duplicate non-idempotent work.
- A consumer with unsafe duplicate schedulers, singleton processes, or
  background work must keep `deploy_standby_sec: 0` until that work is
  coordinated across instances.

## Success criteria

- [ ] A candidate that returns HTTP 500 for the configured public smoke path
      never becomes the committed live color.
- [x] A public smoke response must be 2xx HTML and the public readiness response
      must identify the candidate release, pipeline, and color.
- [ ] After a successful deploy, stopping the live Phoenix service during the
      standby window causes new HTTP requests to reach the previous color.
- [x] The standby is removed from NGINX before its service is stopped.
- [ ] A second deploy or manual rollback cannot let an old timer stop the
      current live color.
- [x] With standby disabled, deployment behavior remains unchanged apart from
      proxy correctness and the new public post-cutover verification.
- [x] NGINX configuration validates when two applications share one host.
- [ ] WebSocket/LiveView clients reconnect after a failed live process; no
      seamless transfer of established sockets is claimed.

## Implementation

### 1. Correct and parameterize the shared NGINX proxy

Files:

- `ansible/roles/web/defaults/main.yml`
- `ansible/roles/web/templates/app.nginx.j2`

Tasks:

- [x] Replace the hardcoded `Connection "upgrade"` header in both proxy
      locations with a per-site `map $http_upgrade` variable.
- [x] Map a non-WebSocket request to an empty `Connection` value, not `close`,
      so upstream keepalive remains possible.
- [x] Add configurable connect, read, send, retry-policy, and retry-count
      defaults.
- [x] Use `proxy_next_upstream error timeout invalid_header` with two tries.
      Exclude HTTP status retries and `non_idempotent`.
- [x] Give each site a unique map variable so multiple vhosts pass `nginx -t`.

Defaults:

```yaml
nginx_connection_upgrade_var: "{{ app_name | replace('-', '_') }}_connection_upgrade"
nginx_proxy_next_upstream: "error timeout invalid_header"
nginx_proxy_next_upstream_tries: 2
nginx_proxy_connect_timeout: "2s"
nginx_proxy_read_timeout: "75s"
nginx_proxy_send_timeout: "75s"
```

### 2. Add bounded standby lifecycle

Files:

- `ansible/roles/phoenix_blue_green/defaults/main.yml`
- `ansible/roles/phoenix_blue_green/tasks/main.yml`
- new
  `ansible/roles/phoenix_blue_green/templates/phoenix_standby_end.sh.j2`
- `ansible/roles/phoenix_blue_green/templates/phoenix_deploy.sh.j2`
- `ansible/roles/phoenix_blue_green/templates/phoenix_rollback.sh.j2`

Defaults:

```yaml
deploy_standby_sec: 0
deploy_standby_end_script: "/usr/local/bin/{{ app_name }}_standby_end"
nginx_upstream_max_fails: 1
nginx_upstream_fail_timeout: "5s"
```

Tasks:

- [x] Add a shared `write_upstream <live_port> [standby_port]` helper. With a
      standby it writes the live server plus a `backup`; without one it writes
      the current single-server form.
- [x] Install a root-owned standby-end script that re-reads `current_color`,
      rewrites NGINX to live-only, reloads NGINX, and only then stops the other
      color.
- [x] Before staging a new release, cancel any pending standby timer and retire
      the old standby. Never overwrite a release beneath a running BEAM.
- [x] After a committed cutover, schedule standby retirement with a transient
      systemd timer. Do not block CI for the standby duration.
- [x] At manual rollback start, cancel the timer. Keep manual rollback
      single-upstream; the known-bad release must not become its backup.

### 3. Make cutover transactional

Files:

- `ansible/roles/phoenix_blue_green/defaults/main.yml`
- `ansible/roles/phoenix_blue_green/templates/phoenix_deploy.sh.j2`

Add consumer-configurable public verification:

```yaml
deploy_public_base_url: "https://{{ server_name }}"
deploy_public_identity_path: "{{ deploy_health_path }}"
deploy_public_smoke_path: "/"
deploy_public_smoke_content_type: "text/html"
deploy_public_smoke_timeout_sec: 15
```

Tasks:

- [x] Keep the existing direct loopback health and artifact-identity check
      before cutover. Treat configured `deploy_health_path` as the consumer's
      readiness-and-identity endpoint; do not assume a literal route name.
- [x] Write the candidate as primary and the current color as backup, validate
      and reload NGINX, but do not update `current_color` yet.
- [x] Through the public HTTPS URL, require:
      1. health JSON identifying the candidate version, release, pipeline, and
         color; and
      2. a 2xx response with an HTML content type from the smoke path.
- [x] If either public check fails, restore the unchanged current color as the
      sole upstream, reload NGINX, stop the candidate, and exit non-zero.
- [x] If both checks pass, update `current_color`, record the deployment,
      schedule standby retirement, and report success.
- [x] Require a public base URL and smoke path for production deployment. Do
      not silently reduce verification to the configured readiness route;
      consumers whose `/` does not return 2xx HTML must select a representative
      path.
- [x] Keep the failed candidate release for diagnosis and the next forward
      deploy; do not undo its migrations.

The public smoke belongs in the host deploy transaction. The existing
`staging_release_smoke` CI job remains useful as an independent external check,
but it runs too late to define whether the host commits its color switch.

### 4. Test, document, and release

Files:

- new `tests/ansible_blue_green_failover_contract_test.sh`
- `.gitlab-ci.yml`
- `README.md`
- `VERSION`

Tasks:

- [x] Add contract tests for NGINX mapping and retry policy, standby defaults,
      timer cancellation, safe standby retirement, transactional
      `current_color`, public identity verification, HTML smoke verification,
      and failed-cutover restoration.
- [x] Add a fixture test where loopback readiness succeeds but the public page
      returns 500. Use a configurable route name and assert that the old color
      remains committed and the deploy fails.
- [x] Run the new contract test and the existing
      `tests/ansible_uploads_contract_test.sh` in `template_smoke`.
- [x] Document the consumer/harness boundary,
      liveness/readiness/synthetic-smoke contract, opt-in safety gate,
      recommended 300-second window, and residual limitations.
- [x] Bump `VERSION` from `0.6.22` to `0.7.0` and update README include refs.

## Verification before release

- [x] Run the repository test suite.
- [x] Provision a host with two applications and pass `nginx -t`.
- [ ] Deploy a fixture whose readiness check passes but public page returns
      500; confirm traffic and `current_color` remain on the previous release.
- [x] Deploy a healthy fixture; confirm both colors answer independently during
      the standby window.
- [ ] Stop the live service mid-window while repeatedly requesting the public
      URL; confirm new requests reach the previous color.
- [x] Confirm the standby timer removes the backup before stopping its service.
- [ ] Start another deploy during the standby window; confirm the stale timer
      cannot affect the new live color.
- [ ] Confirm CI and host notifications distinguish a rejected candidate from
      a successful cutover.
- [ ] Confirm the NGINX error log records a stopped primary and sampled response
      identity proves that the standby served the subsequent requests.

## Residual limitations

- Both Phoenix instances, NGINX, PostgreSQL, and local uploads remain on one
  host. Host, disk, network, NGINX, and database failures are not covered.
- Open-source NGINX performs passive checks. The first request can observe the
  live process failure, and later real requests probe it again after
  `fail_timeout`.
- HTTP application errors after deployment do not trigger runtime NGINX
  failover. They require monitoring and a forward fix.
- Established WebSocket and LiveView connections disconnect and reconnect;
  process-local state may be lost.
- Two releases share one database and may both run scheduled work during the
  standby window.
- Runtime failover is recorded in NGINX logs but does not send a proactive alert
  in this increment.
- Outside the configured window there is no standby.

References:

- [Kubernetes probe semantics][1] provide the liveness/readiness terminology;
  this implementation uses systemd and NGINX, not Kubernetes.
- [NGINX open-source load balancing][2] documents passive health checks,
  `max_fails`, `fail_timeout`, and backup upstreams.
- [NGINX WebSocket proxying][3] documents the required upgrade handling.
- [Phoenix LiveView deployment guidance][4] describes reconnect and recovery.
- [NGINX proxy retry rules][5] define retry conditions and non-idempotent
  behavior.

[1]: https://kubernetes.io/docs/concepts/workloads/pods/probes/
[2]: https://nginx.org/en/docs/http/load_balancing.html
[3]: https://nginx.org/en/docs/http/websocket.html
[4]: https://hexdocs.pm/phoenix_live_view/deployments.html
[5]: https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_next_upstream
