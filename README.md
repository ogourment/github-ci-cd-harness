# gitlab-ci-cd-harness

Reusable GitLab CI/CD templates and recipes for Phoenix/Elixir delivery pipelines.

## Local resource preflight

`scripts/resource_preflight.sh` is a lightweight Linux guard for local compile
and browser test commands. It combines `MemAvailable`, Linux memory PSI, and a
short swap-I/O sample. High historical swap occupancy does not warn on its own
when RAM and current pressure are healthy. Set `RESOURCE_PREFLIGHT_VERBOSE=1`
to report that healthy historical occupancy, or `RESOURCE_PREFLIGHT=off` for an
explicit one-off bypass.

`scripts/intensive_command_lock.sh` prevents two local commands from using the
same intensive resource concurrently. It uses `flock` on Linux and an atomic
directory lock fallback on macOS. A consuming ATDD command can use:

```sh
scripts/intensive_command_lock.sh ecojeux-atdd -- mix test.atdd
```

Choose a lock name that represents the shared test database and browser server,
not merely the shell process. The default is to refuse a concurrent command;
set `RESOURCE_INTENSIVE_LOCK_WAIT=1` to wait for the current holder and then run
automatically. Run the fixture-based tests with
`tests/resource_preflight_test.sh`, `tests/intensive_command_lock_test.sh`, and
`tests/phoenix_test_database_preflight_test.sh`.

`scripts/phoenix_test_database_preflight.sh` protects Phoenix projects that use
linked Git worktrees. It requires a stable `MIX_TEST_PARTITION`, then runs
`MIX_ENV=test mix ecto.create --quiet` before expensive checks. A missing
database fails immediately with a configurable administrator command instead
of surfacing after compilation. Consumers may set
`PHOENIX_TEST_DATABASE_NAME` and `PHOENIX_TEST_DATABASE_OWNER` so the message
names their exact partition database.

The `phoenix_blue_green` and `web` Ansible roles can share persistent uploads
across release colors. Set `phoenix_uploads_dir` with
`phoenix_uploads_env_var`, and set the same directory with
`nginx_uploads_dir` plus `nginx_uploads_url_prefix`. The roles create the
writable directory, expose it to both color services, and serve it directly
through nginx with write methods denied.
Run `tests/ansible_uploads_contract_test.sh` to verify this role contract.

This repository is the renamed successor to `olivierg/gitlab-ci-harness` and the
broader successor to `olivierg/acceptance-gitlab-ci`.

## Provided templates

Include this repository in consuming pipelines:

```yaml
  include:
  - project: olivierg/gitlab-ci-cd-harness
    ref: v0.7.7
    file: /templates/acceptance.yml
  - project: olivierg/gitlab-ci-cd-harness
    ref: v0.7.7
    file: /templates/cd.yml
```

`templates/acceptance.yml` defines:

- `acceptance_evidence`
- `acceptance_gate`
- `acceptance_pages`

Acceptance notifications are sent from `acceptance_gate`'s non-blocking
`after_script`, once evidence is available.

The package also provides `scripts/atdd_remote_eval.sh` for acceptance tests
that need to run a release-scoped Elixir expression over SSH against a deployed
Phoenix release.

`scripts/atdd_remote_copy.sh SOURCE DESTINATION` copies either one file or a
directory tree over the same inventory-backed SSH connection. Copy the complete
evidence directory when a live importer must serve screenshots locally:

```sh
scripts/atdd_remote_copy.sh "$ACCEPTANCE_EVIDENCE_DIR" \
  "/opt/my_app/acceptance_evidence_${CI_PIPELINE_ID}"
```

The importer should then read
`/opt/my_app/acceptance_evidence_${CI_PIPELINE_ID}/evidence.json`; its sibling
`screenshots/` directory remains available to the live application after the CI
runner exits. Use an application-owned persistent parent directory rather than
temporary storage. File-source invocations keep their original non-recursive
behavior. SSH compression is enabled because evidence JSON can be much larger
than its compressed screenshots.

For recurring evidence directories, opt into rsync snapshots so unchanged
screenshots are neither retransmitted nor duplicated on the server:

```sh
scripts/atdd_generate_thumbnails.sh "$ACCEPTANCE_EVIDENCE_DIR"
ATDD_REMOTE_COPY_MODE=rsync-snapshots \
ATDD_REMOTE_COPY_CURRENT_LINK=/opt/my_app/acceptance_evidence_current \
scripts/atdd_remote_copy.sh "$ACCEPTANCE_EVIDENCE_DIR" \
  "/opt/my_app/acceptance_evidence_${CI_PIPELINE_ID}_${CI_JOB_ID}"
```

This mode requires `rsync` in both the CI image and on the remote host. It uses
checksums because CI recreates file timestamps, compression in transit, and
`--link-dest` against the last successfully copied snapshot. Identical files
become hard links in the new run-specific directory; changed files use rsync's
block delta transfer. Regenerated timestamps are intentionally not preserved,
so equal content remains hard-link eligible. Set
`ATDD_REMOTE_COPY_STATS_FILE` to persist rsync's transfer statistics for the CI
artifact; the file is written atomically after a successful copy. The
`acceptance_evidence_current` symlink advances only
after a complete transfer, so failed jobs and retries retain a valid basis.
The first run, or a run after the symlink is removed, transfers everything.
The shared `acceptance_evidence` job uses a project-scoped GitLab
`resource_group`, preventing concurrent pipelines from racing while updating
the symlink. The copy helper additionally compares the pipeline and job IDs in
the strictly validated snapshot names and refuses to move the link backward if
GitLab schedules serialized pipelines out of order.

`atdd_generate_thumbnails.sh` requires ImageMagick (`magick` or `convert`) in
the CI image. It converts each top-level `screenshots/*.png` into
`thumbnails/<name>.webp` at quality 70, strips metadata, and limits width to 480
pixels without enlarging smaller images. Full-page height remains proportional.
Outputs are replaced atomically, so a failed conversion cannot overwrite the
last complete thumbnail. Set `ATDD_THUMBNAIL_STATS_FILE` to persist source,
thumbnail, saved-byte, count, and duration metrics. On Debian-based CI images,
install the prerequisites with
`apt-get install --no-install-recommends imagemagick rsync`.

Successful live-evidence commands may print sanitized lines beginning with
`ACCEPTANCE_METRIC `. The acceptance template retains only those lines in
`live_evidence_metrics.log`; the final magic-link URL remains ephemeral and is
never copied into the artifact.

`templates/cd.yml` defines:

- `build_release`
- `release_tag` (off by default; manual)
- `deploy_staging`
- `staging_release_smoke`
- `deploy_prod` (off by default)
- `deploy_staging_ansible` (off by default)
- `deploy_prod_ansible` (off by default)

The job dependency chain encoded by the template is:

```text
build_release -> deploy_staging -> staging_release_smoke -> deploy_prod
                              -> acceptance_evidence -> acceptance_gate -> deploy_prod
```

Production deploys remain optional. Set `CI_CD_ENABLE_PROD_DEPLOY=true` in a
consumer to expose the manual production deploy job. Optional manual deploy
jobs are non-blocking, so a green pipeline stays green when they are not run.

## Staging browser smoke

`staging_release_smoke` is enabled by default for a staging deployment. It
requests `STAGING_ENVIRONMENT_URL` after deployment, requires a 2xx response,
and verifies that the response is an HTML document. This catches failures in
the root layout or page rendering that a JSON health endpoint cannot see.

Set `CI_CD_STAGING_SMOKE_URL` when the public browser URL differs from
`STAGING_ENVIRONMENT_URL`. Consumers with no browser surface can explicitly
set `CI_CD_ENABLE_STAGING_SMOKE=false`.

## SemVer release tags

Set `CI_CD_ENABLE_RELEASE_TAG=true` to expose the `release_tag` manual job on
`main`. It evaluates `CI_CD_RELEASE_VERSION_COMMAND` (by default, the
`version:` value in `mix.exs`), requires strict `MAJOR.MINOR.PATCH` SemVer, and
creates an annotated `vMAJOR.MINOR.PATCH` tag at the current pipeline commit.
It refuses to replace an existing tag.

The consumer project must enable **Allow Git push requests to the repository**
for its own CI/CD job tokens. The job token uses the permissions of the person
who starts the manual job, so protect `v*` tags and restrict tag creation to
Maintainers in the project settings. GitLab does not create another pipeline
for the tag push.

## Required consumer configuration

Consumers provide app identity, host variables, and secrets. The harness owns the
deploy job body and generic deploy scripts.

### Health identity contract

Fast and Ansible-managed blue/green deploys require the deployed health JSON to
identify the exact artifact before nginx cutover. The response must contain
matching `version`, `release_id`, and `pipeline_id`; the on-host check also
requires the expected blue/green `color`. Identity mismatches report expected
and actual values and leave the previous color live.

The Ansible role writes release and pipeline identity into the target slot's
environment before systemd starts it. Configure the variable names that the
application's health payload reads:

```yaml
phoenix_release_id_env_var: "MY_APP_RELEASE_ID"
phoenix_pipeline_id_env_var: "MY_APP_CI_PIPELINE_ID"
```

Both `/health` and any application-specific `/health/deep` endpoint should
extend the same health payload so either endpoint reports identical deployment
identity.

### Bounded same-host failover

The Ansible roles can keep the previous blue/green color as an NGINX backup for
a short post-deploy window. This is release resilience on one host, not
host-level HA: NGINX, PostgreSQL, storage, and both application processes still
share the same machine.

The feature is off by default. A consumer may start with:

```yaml
deploy_standby_sec: 300
deploy_health_path: "/health/deep"
deploy_public_smoke_path: "/"
app_health_watch_interval_sec: 15
app_health_watch_failure_threshold: 2
app_health_watch_action_cooldown_sec: 300
```

Consumers migrating an existing blue/green host can preserve its release
archive interface, real-directory slots, env-file names, and systemd command:

```yaml
deploy_release_artifact_kind: "archive"
deploy_slot_layout: "directory"
deploy_archive_strip_components: 1
app_slot_env_file_template: "/etc/my_app/my_app-%s.env"
app_slot_metadata_env_file_template: "/etc/my_app/my_app-%s-deploy.env"
app_service_environment_files:
  - "/etc/my_app/my_app.env"
  - "/etc/my_app/my_app-%i.env"
  - "/etc/my_app/my_app-%i-deploy.env"
app_service_exec_start: "/opt/my_app/slots/%i/bin/server"
release_seed_after_migrate: false
deployment_history_path: "/var/lib/my_app/deployments.jsonl"
nginx_upstream_keepalive: 32
phoenix_release_node_template: "my_app_%s"
```

The defaults remain the harness-native directory artifact, symlink slots,
underscore-named slot env file, OTP release start command, post-migration seed
hook, per-color `RELEASE_NODE`, and no host JSON history. Set
`app_service_on_failure` when an existing unit has an alert target that must be
retained.

Use a separate `app_slot_metadata_env_file_template` when Ansible may refresh
runtime credentials after deployments. The deploy helper writes release,
pipeline, Git, actor, and deployment timestamps only to that metadata file, so
rendering the static slot environment cannot erase the identity later reported
by readiness and audit tools. List the metadata file after the static slot file
in `app_service_environment_files`.

Enable it only after confirming that migrations remain backward-compatible
and that two release instances cannot duplicate unsafe scheduled, singleton,
or background work. The consumer supplies and tests the configured readiness
endpoint. It must return 2xx JSON only when required application dependencies
are available and include `version`, `release_id`, `pipeline_id`, and `color`.
The consumer also selects an unauthenticated HTML path that exercises real
production rendering.

The host deploy first validates readiness and identity directly on the
candidate port. It then makes the candidate primary with the current color as
backup, validates the same identity and an HTML smoke request through public
HTTPS, and only then commits `current_color`. A failed public check restores
the previous color as the sole upstream and stops the candidate. The deploy
fails for a forward fix; migrations and releases are not rolled back
automatically.

When `app_health_watch_interval_sec` is positive, a systemd timer continuously
checks the committed color's direct readiness endpoint and the configured
public HTML smoke path. It requires `app_health_watch_failure_threshold`
consecutive failures before acting. During the standby window it verifies the
other color directly, atomically makes that color live-only in NGINX, updates
the committed color, stops the unhealthy process, records the event, and rings
an operator alert. Without a healthy standby it restarts the committed service
and rings an alert. A cooldown prevents repeated recovery actions during a
persistent outage.

Deploy, rollback, standby retirement, and health-watch changes share
`deploy_operation_lock_path`; they cannot concurrently rewrite NGINX or the
committed-color pointer.

Consumers can manage durable crash evidence and the `OnFailure` unit through:

```yaml
app_manage_failure_alert_unit: true
app_service_on_failure: "my_app-alert@%i.service"
app_failure_history_path: "/var/lib/my_app/failures.jsonl"
app_failure_alert_cooldown_sec: 300
telegram_verify_on_provision: true
```

Every systemd failure is written to the bounded JSONL ledger with its result,
exit code or signal, restart count, timestamps, concise cause, and recent
journal tail. Telegram delivery is rate-limited, but evidence capture is not.
Alerts include the exact `journalctl` command for deeper investigation.

The host Telegram wrapper validates Telegram's JSON response and returns
non-zero for missing credentials, transport failures, non-2xx responses, and
API-level rejection. `telegram_verify_on_provision` performs read-only `getMe`
and `getChat` checks after slot environments are rendered. Deployment
notifications remain best-effort so a notification outage cannot turn a
healthy release into a failed deploy; delivery failure is nevertheless visible
in CI or journald.

NGINX retries connection, timeout, and invalid-header failures on the backup.
It deliberately does not retry generic HTTP 5xx responses or non-idempotent
requests. The first failed request may therefore still fail, established
WebSocket connections must reconnect, and there is no standby after the
configured window.

The recurring monitor is what handles readiness HTTP errors and public-smoke
HTTP 500 responses; NGINX itself still does not retry generic HTTP responses or
non-idempotent requests.

Use `STAGING_HOST` / `PROD_HOST` for public environment hostnames used by
health and websocket checks. Set `STAGING_SSH_HOST` / `PROD_SSH_HOST` only when
SSH should connect to a different host or address; by default SSH uses the
public host.

Fast SSH deploys call the remote deploy helper with app-prefixed metadata
environment variables. The default prefix is the uppercased `CI_CD_OTP_APP`
value, for example `AGILE_U_APP_NAME`, `AGILE_U_APP_VERSION`,
`AGILE_U_GIT_SHA`, `AGILE_U_GIT_MESSAGES`, `AGILE_U_DEPLOY_ACTOR`,
`AGILE_U_CI_PIPELINE_ID`,
`AGILE_U_CI_PIPELINE_URL`,
`AGILE_U_CI_JOB_ID`, `AGILE_U_CI_JOB_WAIT_SECONDS`, and
`AGILE_U_CI_PIPELINE_CREATED_AT_EPOCH`.
Each line in `AGILE_U_GIT_MESSAGES` begins with its short commit SHA so
deployment history can show an auditable `SHA message` list.
Override the prefix with
`CI_CD_REMOTE_ENV_PREFIX` only when the remote helper already expects another
name.

By default, a successful fast deploy produces both a host-side message and the
CI summary. Set `CI_CD_HOST_DEPLOY_NOTIFY=false` when CI is the canonical
notifier; deployment failures still notify from the host. The CI summary reads
the active blue/green color from the verified health response when available.

See [migrating-to-gitlab-ci-cd-harness](docs/migrating-to-gitlab-ci-cd-harness.md).

## Compatibility

Projects already using `templates/acceptance.yml` can migrate first by changing
the include project path. Add `templates/cd.yml` when ready to move deployment
job bodies out of the consumer repository.

## Required variables

Set at least:

```yaml
variables:
  ACCEPTANCE_APP_NAME: "My App"
  CI_CD_APP_NAME: "My App"
  ACCEPTANCE_APP_OTP_NAME: "my_app"
  ACCEPTANCE_ENVIRONMENT: "staging-release-after-deploy"
  ACCEPTANCE_TARGET: "staging"
  ACCEPTANCE_BASE_URL: "https://staging.example.com"
  ACCEPTANCE_TEST_COMMAND: "mix test.atdd"
  ACCEPTANCE_EVIDENCE_DIR: "tmp/atdd"
  ACCEPTANCE_PUBLIC_DIR: "public"
  ACCEPTANCE_SITE_TIMEOUT_SECONDS: "90"
```

## Optional variables

```yaml
variables:
  ACCEPTANCE_APP_VERSION: ""                      # fallback shown in summary
  ACCEPTANCE_TELEGRAM_MESSAGE_PATH: "acceptance_summary.txt"
  CI_CD_ALERT_ADAPTER: ""                          # executable receiving one ops-alert-event.v1 JSON file
  CI_CD_ALERT_HELPER: ""                           # optional path override for scripts/ci_cd_alert_event.sh
  ACCEPTANCE_NOTIFY_COMMAND: ""                    # deprecated compatibility notifier
  ACCEPTANCE_REMOTE_INVENTORY: ""
  ACCEPTANCE_REMOTE_APP_ROOT: ""
  ACCEPTANCE_REMOTE_ENV_DIR: ""
  ACCEPTANCE_REMOTE_APP_USER: ""
  ACCEPTANCE_REMOTE_APP_NAME: ""
  ACCEPTANCE_REMOTE_SSH_KEY_FILE: ""
  ACCEPTANCE_FORCE_FAILURE: "false"
  ACCEPTANCE_FORCE_FAILURE_CODE: "42"
  ACCEPTANCE_SITE_TIMEOUT_SECONDS: "90"              # hard cap for `mix acceptance.site`; its log is retained in the evidence artifact
```

`ACCEPTANCE_TELEGRAM_MESSAGE_PATH` is interpreted as a filename relative to
`$ACCEPTANCE_EVIDENCE_DIR`.

## Alert delivery and notification policy

Set `CI_CD_ALERT_ADAPTER` to an executable to route acceptance and deployment
outcomes to an alerting service. The harness invokes it without a shell:

```sh
"$CI_CD_ALERT_ADAPTER" "$event_file"
```

The event file uses the `ops-alert-event.v1` contract and includes:

- stable `id` and `idempotency_key` values derived from the project, pipeline,
  job, event kind, result, and environment;
- RFC 3339 `occurred_at` plus an explicit `timezone`;
- source, kind, severity, status, application, environment, and host;
- pipeline, job, release, and commit identifiers and URLs;
- `fingerprint` and `correlation_key` values for incident grouping;
- a short summary, details, and evidence path/URL.

The adapter is opt-in. When it is unset, the existing Telegram sender remains
the default. A configured adapter failure is logged but does not fall through
to Telegram, preventing duplicate delivery, and notification transport never
changes the deploy or acceptance result.

`acceptance_gate` obtains the shared event helper only when the adapter is
enabled. Set `CI_CD_HARNESS_REF` to the same immutable harness tag used by the
consumer includes. Deploy jobs already fetch that harness checkout.

`ACCEPTANCE_NOTIFY_COMMAND` remains available for migration but is deprecated.
It is considered only when `CI_CD_ALERT_ADAPTER` is unset. Its existing message
environment remains unchanged.

CI/CD Telegram notifications follow one bell policy across templates:
successful acceptance and deployment messages are sent with
`disable_notification=true`, while failed acceptance and deployment messages are
sent with `disable_notification=false`.

The built-in acceptance Telegram sender applies this directly. Deprecated
`ACCEPTANCE_NOTIFY_COMMAND` scripts receive `ACCEPTANCE_NOTIFY_SILENT=true` for
successful acceptance and `false` for failures.

Generated deploy helpers call an app-local Telegram wrapper with
`TELEGRAM_SILENT=true` on success and `TELEGRAM_SILENT=false` on failure.

If you already use an existing `pages` job, keep it as-is and call it separately from
the template job. This template only defines `acceptance_pages`.

For faster Playwright-backed acceptance jobs, use a prebuilt Elixir/Playwright CI image.
See [docs/ci_ghcr_image_recipe.md](docs/ci_ghcr_image_recipe.md).

For a complete Phoenix project handoff recipe, including Telegram notifications
and release artifact/cache hygiene for deploy jobs, see
[docs/phoenix_acceptance_ci_recipe.md](docs/phoenix_acceptance_ci_recipe.md).

## Notes

- Evidence artifacts and site output are published even when acceptance fails.
- The evidence job exposes its generated site through that job's immutable
  artifact URL. Live evidence importers should store this URL to keep historical
  release links tied to the matching pipeline; `CI_PAGES_URL` always points at
  the latest Pages deployment instead.
- `acceptance_gate` is the explicit blocking gate.
- The acceptance gate sends a notification after it has consumed the evidence.
  This avoids a no-op notification when an earlier staging deploy fails and is
  retried in the same pipeline. Notification transport is best-effort and never
  changes the acceptance-gate result. Configure it with Telegram Bot API
  variables or `ACCEPTANCE_NOTIFY_COMMAND`.
