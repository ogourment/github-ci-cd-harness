# Migrating to gitlab-ci-cd-harness

`gitlab-ci-cd-harness` replaces `gitlab-ci-harness`.

The old package only owned acceptance CI jobs. The renamed package owns both CI
acceptance gates and optional CD jobs for Phoenix releases. Production deploys
remain opt-in and are disabled by default.

## Package rename

Update GitLab includes:

```yaml
include:
  - project: "olivierg/gitlab-ci-cd-harness"
    ref: "v0.2.5"
    file: "/templates/acceptance.yml"
  - project: "olivierg/gitlab-ci-cd-harness"
    ref: "v0.2.5"
    file: "/templates/cd.yml"
```

Archive the old `olivierg/gitlab-ci-harness` project after all consumers use the
new include path.

## Required CD variables

Set the app identity and release artifact mode:

```yaml
variables:
  CI_CD_OTP_APP: "my_app"
  CI_CD_RELEASE_ARTIFACT_KIND: "directory" # or "archive"
```

For staging:

```yaml
variables:
  STAGING_HOST: "staging.example.com"
  STAGING_SSH_HOST: "203.0.113.10" # optional; defaults to STAGING_HOST
  STAGING_SSH_USER: "deploy"
  STAGING_REMOTE_DEPLOY_SCRIPT: "/usr/local/bin/my_app_deploy"
  STAGING_HEALTH_URL: "https://staging.example.com/health"
  STAGING_ENVIRONMENT_URL: "https://staging.example.com"
```

For production, explicitly opt in:

```yaml
variables:
  CI_CD_ENABLE_PROD_DEPLOY: "true"
  PROD_HOST: "example.com"
  PROD_SSH_HOST: "203.0.113.11" # optional; defaults to PROD_HOST
  PROD_SSH_USER: "deploy"
  PROD_REMOTE_DEPLOY_SCRIPT: "/usr/local/bin/my_app_deploy"
  PROD_HEALTH_URL: "https://example.com/health"
  PROD_ENVIRONMENT_URL: "https://example.com"
```

The production deploy job is manual and non-blocking. Enabling it exposes the
job without forcing every successful pipeline to remain in a manual state.

The protected/masked key variables remain `STAGING_SSH_PRIVATE_KEY` and
`PROD_SSH_PRIVATE_KEY`.

Use `STAGING_HOST` / `PROD_HOST` for public health and websocket verification.
Use `STAGING_SSH_HOST` / `PROD_SSH_HOST` when deploy traffic must SSH or rsync to
a different host, such as an IP address or a reused server with another public
TLS hostname.

## Remote deploy metadata

The fast SSH deploy script passes deployment metadata through `sudo env` to the
remote helper. By default, variable names use an uppercased app prefix derived
from `CI_CD_OTP_APP`, so `CI_CD_OTP_APP: "agile_u"` produces:

```text
AGILE_U_APP_VERSION
AGILE_U_GIT_SHA
AGILE_U_GIT_REF
AGILE_U_GIT_SUBJECT
AGILE_U_GIT_MESSAGES
AGILE_U_DEPLOY_ACTOR
AGILE_U_CI_JOB_WAIT_SECONDS
AGILE_U_CI_PIPELINE_CREATED_AT_EPOCH
```

Remote helpers that send deployment alerts should read those variables instead
of inferring release details from the server user or filesystem state. Set
`CI_CD_REMOTE_ENV_PREFIX` only when an existing helper expects a different
prefix.

## Ansible

The package includes a generic Phoenix blue/green Ansible role. Consumers should
keep inventory and group vars in the app repo, but move reusable roles, playbooks,
templates, deploy scripts, and deploy job bodies into this package.

Enable host-state jobs only when needed:

```yaml
variables:
  CI_CD_ENABLE_ANSIBLE_DEPLOY_JOBS: "true"
  STAGING_ANSIBLE_INVENTORY: "infrastructure/inventory/staging"
  PROD_ANSIBLE_INVENTORY: "infrastructure/inventory/prod"
```

Use host provisioning for repeatable runtime state instead of ad hoc server
changes. App-specific OS dependencies belong in inventory through
`phoenix_runtime_extra_packages`:

```yaml
phoenix_runtime_extra_packages:
  - imagemagick
  - librsvg2-bin
```

The role installs the base Phoenix release dependencies plus those extra
packages before writing the env file, systemd service, nginx site, deploy helper,
and sudoers rule.
