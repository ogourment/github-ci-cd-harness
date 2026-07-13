# gitlab-ci-cd-harness

Reusable GitLab CI/CD templates and recipes for Phoenix/Elixir delivery pipelines.

This repository is the renamed successor to `olivierg/gitlab-ci-harness` and the
broader successor to `olivierg/acceptance-gitlab-ci`.

## Provided templates

Include this repository in consuming pipelines:

```yaml
include:
  - project: olivierg/gitlab-ci-cd-harness
    ref: v0.3.0
    file: /templates/acceptance.yml
  - project: olivierg/gitlab-ci-cd-harness
    ref: v0.3.0
    file: /templates/cd.yml
```

`templates/acceptance.yml` defines:

- `acceptance_evidence`
- `acceptance_gate`
- `acceptance_pages`
- `acceptance_notify`

The package also provides `scripts/atdd_remote_eval.sh` for acceptance tests
that need to run a release-scoped Elixir expression over SSH against a deployed
Phoenix release.

`templates/cd.yml` defines:

- `build_release`
- `release_tag` (off by default; manual)
- `deploy_staging`
- `deploy_prod` (off by default)
- `deploy_staging_ansible` (off by default)
- `deploy_prod_ansible` (off by default)

The job dependency chain encoded by the template is:

```text
build_release -> deploy_staging -> acceptance_evidence -> acceptance_gate -> deploy_prod
```

Production deploys remain optional. Set `CI_CD_ENABLE_PROD_DEPLOY=true` in a
consumer to expose the manual production deploy job. Optional manual deploy
jobs are non-blocking, so a green pipeline stays green when they are not run.

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
- `acceptance_notify` always runs in `production` stage and can be configured to
  send notifications directly through Telegram Bot API or via `ACCEPTANCE_NOTIFY_COMMAND`.
