# GitLab-to-GitHub migration

## Available now

- reusable Phoenix CI with PostgreSQL;
- optional Playwright acceptance execution with retained evidence artifacts;
- optional production OTP release artifacts;
- reusable Ansible lint and syntax validation;
- all upstream shell tests and deployment helpers;
- the upstream Ansible roles;
- preserved Git history and tags.

## Still GitLab-specific

- `templates/acceptance.yml`;
- `templates/cd.yml`;
- pipeline/job environment-variable conventions in deployment scripts;
- GitLab Pages acceptance evidence;
- job-token release tagging.

These interfaces remain as migration references. They are not advertised as
GitHub-native until their behavior has contract tests using GitHub event and
environment semantics.

## Planned GitHub interfaces

1. deploy staging with GitHub environment protection and concurrency;
2. run post-deploy browser smoke against the staging artifact;
3. require explicit production approval;
4. promote the exact tested artifact;
5. create an idempotent release tag and GitHub Release.
