# gitlab-ci-harness

Reusable GitLab CI templates and recipes for Phoenix/Elixir delivery pipelines.

This repository is the broader successor to `olivierg/acceptance-gitlab-ci`. The
old repository remains available as a compatibility include source while projects
migrate progressively.

## Provided template

Include this repository in consuming pipelines:

```yaml
include:
  - project: olivierg/gitlab-ci-harness
    ref: v0.1.8
    file: /templates/acceptance.yml
```

This file defines:

- `acceptance_evidence`
- `acceptance_gate`
- `acceptance_pages`
- `acceptance_notify`

The job dependency chain encoded by the template is:

```text
deploy_staging -> acceptance_evidence -> acceptance_gate
```

`deploy_prod` **must** depend on `acceptance_gate` in the consuming project.

## Required consumer jobs

Consumers are responsible for these existing jobs:

- `build_release`
- `deploy_staging`
- `deploy_prod`

`acceptance_evidence` needs `deploy_staging` artifacts, and `acceptance_gate` depends on
`acceptance_evidence`.

`deploy_prod` should declare `acceptance_gate` in `needs` so production deployment cannot proceed
when acceptance fails.

## Required variables

Set at least:

```yaml
variables:
  ACCEPTANCE_APP_NAME: "My App"
  ACCEPTANCE_APP_OTP_NAME: "my_app"
  ACCEPTANCE_ENVIRONMENT: "staging-release-after-deploy"
  ACCEPTANCE_TARGET: "staging"
  ACCEPTANCE_BASE_URL: "https://staging.example.com"
  ACCEPTANCE_TEST_COMMAND: "mix test.atdd"
  ACCEPTANCE_EVIDENCE_DIR: "tmp/atdd"
  ACCEPTANCE_PUBLIC_DIR: "public"
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
```

`ACCEPTANCE_TELEGRAM_MESSAGE_PATH` is interpreted as a filename relative to
`$ACCEPTANCE_EVIDENCE_DIR`.

## Consumer integration examples

Example deploy gating:

```yaml
deploy_prod:
  stage: deploy
  needs:
    - job: build_release
      artifacts: true
    - job: acceptance_gate
      artifacts: true
```

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
