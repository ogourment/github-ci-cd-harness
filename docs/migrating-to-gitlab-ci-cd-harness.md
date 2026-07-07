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
    ref: "v0.2.0"
    file: "/templates/acceptance.yml"
  - project: "olivierg/gitlab-ci-cd-harness"
    ref: "v0.2.0"
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
  PROD_SSH_USER: "deploy"
  PROD_REMOTE_DEPLOY_SCRIPT: "/usr/local/bin/my_app_deploy"
  PROD_HEALTH_URL: "https://example.com/health"
  PROD_ENVIRONMENT_URL: "https://example.com"
```

The protected/masked key variables remain `STAGING_SSH_PRIVATE_KEY` and
`PROD_SSH_PRIVATE_KEY`.

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
