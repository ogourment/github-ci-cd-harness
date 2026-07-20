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
not merely the shell process. Run the fixture-based tests with
`tests/resource_preflight_test.sh` and `tests/intensive_command_lock_test.sh`.

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
    ref: v0.6.9
    file: /templates/acceptance.yml
  - project: olivierg/gitlab-ci-cd-harness
    ref: v0.6.9
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

Use `STAGING_HOST` / `PROD_HOST` for public environment hostnames used by
health and websocket checks. Set `STAGING_SSH_HOST` / `PROD_SSH_HOST` only when
SSH should connect to a different host or address; by default SSH uses the
public host.

Fast SSH deploys call the remote deploy helper with app-prefixed metadata
environment variables. The default prefix is the uppercased `CI_CD_OTP_APP`
value, for example `AGILE_U_APP_NAME`, `AGILE_U_APP_VERSION`,
`AGILE_U_GIT_SHA`, `AGILE_U_DEPLOY_ACTOR`, `AGILE_U_CI_PIPELINE_ID`,
`AGILE_U_CI_JOB_ID`, `AGILE_U_CI_JOB_WAIT_SECONDS`, and
`AGILE_U_CI_PIPELINE_CREATED_AT_EPOCH`.
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
  ACCEPTANCE_NOTIFY_COMMAND: ""                     # custom notifier; e.g. script that reads the message from a file
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

## Notification policy

CI/CD Telegram notifications follow one bell policy across templates:
successful acceptance and deployment messages are sent with
`disable_notification=true`, while failed acceptance and deployment messages are
sent with `disable_notification=false`.

The built-in acceptance Telegram sender applies this directly. Custom
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
- `acceptance_gate` is the explicit blocking gate.
- The acceptance gate sends a notification after it has consumed the evidence.
  This avoids a no-op notification when an earlier staging deploy fails and is
  retried in the same pipeline. Notification transport is best-effort and never
  changes the acceptance-gate result. Configure it with Telegram Bot API
  variables or `ACCEPTANCE_NOTIFY_COMMAND`.
