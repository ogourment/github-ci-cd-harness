# Phoenix acceptance CI and Telegram recipe

Use this recipe after the consuming Phoenix app has integrated `acceptance_harness` and has a working `mix test.atdd` command.

## Goal

The pipeline should run this lifecycle:

```text
dev -> push -> staging -> acceptance -> gate -> production
```

Acceptance evidence must be published even when the browser tests fail. Production deploy must depend on `acceptance_gate`.

## 1. Include the shared template

```yaml
include:
  - project: "olivierg/gitlab-ci-harness"
    ref: "v0.1.8"
    file: "/templates/acceptance.yml"
```

The template defines:

- `acceptance_evidence`
- `acceptance_gate`
- `acceptance_pages`
- `acceptance_notify`

## 2. Required app jobs

The consuming app remains responsible for:

- `build_release`
- `deploy_staging`
- `deploy_prod`
- any app-specific `pages` job, if the project already publishes GitLab Pages

The shared template assumes `deploy_staging` has completed before acceptance starts.

## 3. Configure `acceptance_evidence`

Minimal staging-backed example:

```yaml
acceptance_evidence:
  variables:
    ACCEPTANCE_APP_NAME: "My App"
    ACCEPTANCE_APP_OTP_NAME: "my_app"
    ACCEPTANCE_ENVIRONMENT: "staging-release-after-deploy"
    ACCEPTANCE_TARGET: "staging"
    ACCEPTANCE_BASE_URL: "https://staging.example.com"
    ACCEPTANCE_EVIDENCE_DIR: "tmp/atdd"
    ACCEPTANCE_PUBLIC_DIR: "public"
    ACCEPTANCE_TELEGRAM_MESSAGE_PATH: "telegram_message.txt"
    ACCEPTANCE_TEST_COMMAND: "mix test.atdd"
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
```

If the project runs browser tests against a CI-local server instead of staging, set:

```yaml
variables:
  ACCEPTANCE_TARGET: "ci-local"
  ACCEPTANCE_BASE_URL: "http://localhost:4002"
  ACCEPTANCE_TEST_COMMAND: "MIX_ENV=test ATDD=true mix test --include slow --only atdd --max-cases 1"
```

## 4. Publish the evidence site

If the project does not have its own `pages` job, use the template's `acceptance_pages` job.

If the project already has a `pages` job, keep it and depend on `acceptance_evidence` artifacts:

```yaml
pages:
  stage: verify
  needs:
    - job: acceptance_evidence
      artifacts: true
  script:
    - test -f public/index.html
    - find public -maxdepth 3 -type f | sort
  artifacts:
    paths:
      - public
```

Then point `acceptance_notify` at the actual pages job:

```yaml
acceptance_notify:
  needs:
    - job: acceptance_evidence
      artifacts: true
    - job: pages
      artifacts: false
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      when: always
```

## 5. Gate production

Production deploy must depend on `acceptance_gate`, not only on `acceptance_evidence`.

```yaml
deploy_prod:
  stage: production
  needs:
    - job: build_release
      artifacts: true
    - job: deploy_staging
      artifacts: false
    - job: acceptance_evidence
      artifacts: true
    - job: acceptance_gate
      artifacts: false
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
```

`acceptance_evidence` can succeed while the tests failed, because it still has to publish artifacts and build the evidence site. `acceptance_gate` is the blocking job.

## 6. Telegram notifications

Set these CI variables in the consuming project:

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

The template sends through Telegram Bot API when both variables exist and `ACCEPTANCE_NOTIFY_COMMAND` is empty.

The generated message starts with a status icon and includes:

- app name
- app version
- pipeline and job ids
- evidence report link
- scenario and step counts
- test and gate exit codes
- elapsed time
- first failure summary when present

Example shape:

```text
✅ Acceptance passed
App: `My App`
Version: `v0.1.2`
Pipeline: `123456` job `789`
Evidence report: open report
Evidence: 9 scenario(s), 42 step(s)
Exit: test `0`, gate `0`
Finished in `5m 12s`.
```

For a custom notifier, set:

```yaml
variables:
  ACCEPTANCE_NOTIFY_COMMAND: 'node scripts/telegram_notify.mjs "$ACCEPTANCE_MESSAGE_PATH"'
```

Prefer leaving this unset unless the app needs a custom transport. The shared template owns the default operator message.

## 7. CI image recommendation

Use a prebuilt Elixir/Playwright image for browser-heavy acceptance jobs:

```yaml
default:
  image: "$APP_CI_IMAGE_REGISTRY/ci-elixir-playwright:$APP_CI_IMAGE_TAG"

variables:
  APP_CI_IMAGE_REGISTRY: "ghcr.io/ogourment/agile-u"
  APP_CI_IMAGE_TAG: "elixir-1.18.4-erlang-28.0.1-bookworm-playwright-1.61.1-v1"
  PLAYWRIGHT_BROWSERS_PATH: "/ms-playwright"
```

Set `DOCKER_AUTH_CONFIG` in Framagit so runners can pull the private GHCR image.

Do not run `npx playwright install --with-deps chromium` in jobs that use this image. The browser is already installed under `PLAYWRIGHT_BROWSERS_PATH`.

See [ci_ghcr_image_recipe.md](ci_ghcr_image_recipe.md) for details and timing measurements.

## 8. Stable-IP external integrations

Framagit shared runners do not have stable IPs. Do not call IP-allowlisted providers, such as Brevo, directly from runner-side tests.

For staging-backed ATDD:

- keep provider credentials on the staging host
- use app-specific remote eval or release helpers to seed/check provider state
- use dedicated ATDD prefixes, lists, users, and database objects
- explicitly unset provider API keys before local runner-side `mix test.atdd` when needed

The runner should orchestrate the browser and evidence collection. Staging should perform calls that require stable outbound IP.

## 9. Handoff checklist

- `acceptance_harness` is added to `mix.exs` and `mix.lock`.
- `mix test.atdd` exists and runs only acceptance scenarios.
- Evidence paths are configured under `tmp/atdd`.
- Scenarios call `record_pending_step/4` before fragile assertions.
- `gitlab-ci-harness@v0.1.8` is included.
- `acceptance_evidence` sets app name, target, base URL, evidence dir, public dir, and test command.
- `acceptance_gate` is required by `deploy_prod`.
- Evidence publishing runs even on failed acceptance.
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are set.
- `DOCKER_AUTH_CONFIG` is set if using the private GHCR image.
- Provider/API calls that need stable IP are delegated to staging, not the runner.
