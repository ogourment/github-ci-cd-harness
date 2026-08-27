# ci_cd_harness

Provider-neutral CI/CD delivery for Elixir applications, consumed as a tagged
git dependency.

## Why this exists

The predecessor was shared through GitLab's `include: project:file:ref`, which
Forgejo has no equivalent for. Rather than copy its scripts into each
application — leaving several divergent implementations of the same delivery
logic — the shared behaviour moves here and is versioned through `mix.lock`,
with the same immutability as the predecessor's pinned tag.

The canonical name carries no forge, deliberately. A provider-specific name
became misleading the moment a second forge appeared; renaming it after each
provider migration would repeat the mistake.

## Design

Forge-specific code is thin. An adapter answers three questions — what commit,
what run, and where do artifacts live — and everything downstream is written
once against the normalized answers:

```text
lib/ci_cd_harness.ex          forge detection and normalization
lib/mix/tasks/cd.*.ex         provider-neutral entry points
priv/core/                    shared shell, identical on every forge
                              (delivery, tagging, acceptance, test budgets)
priv/forges/forgejo/          adapter scripts, where shell is the right tool
```

`priv/core/acceptance_evidence.sh` runs the acceptance suite, builds the
evidence site, evaluates the gate and writes the notification message. It is the
GitLab template's logic verbatim, with one input made explicit:
`ACCEPTANCE_REPORT_URL`, because each forge addresses run artifacts differently.
The GitLab adapter derives an immutable job-artifact URL when a consumer does
not provide an explicit live evidence URL.
Evidence is produced even when scenarios fail — the gate is a separate step.

`CiCdHarness.normalized_env/0` maps Forgejo's GitHub-compatible variables onto
the `CI_*` names the existing deployment shell already understands. That is the
seam that lets proven scripts run unchanged under a new forge instead of being
rewritten.

## Usage

```elixir
{:ci_cd_harness, git: "https://git.agile-u.com/olivierg/ci-cd-harness.git", tag: "v0.4.34", only: [:dev, :test], runtime: false}
```

Build a release with a traceable identity:

```sh
mix cd.build_release
```

Writes `_build/RELEASE_ID`, `VERSION`, `RELEASE_ARCHIVE` and `RELEASE_SHA256`.
The release ID is `v<version>-<short sha>-<run id>`, stable across build, deploy
and verify so an artifact traces back to the run and commit that produced it.

## The bootstrap exception

`priv/forges/forgejo/setup_private_deps.sh` installs the SSH keys that let
`mix deps.get` reach any remaining private dependencies. This package itself is
publicly readable over HTTPS, so consumers do not need a Forgejo credential to
fetch it. Applications that still have private dependencies keep a copy of the
bootstrap script in their own repository and run it before `deps.get`;
everything after dependency resolution comes from this package.

## Delivery scripts

`priv/core/` carries the delivery layer: blue/green deploy, health identity
verification, SemVer tag preflight and publication, acceptance evidence, remote
evidence copy and evaluation, and the ExUnit budget and value audits.

These previously lived in a repository each consumer cloned at a fixed
directory name, and referred to each other through that name — so a consumer
that cloned it elsewhere got a deploy that ran, reported success, and then
failed on a missing sibling *after* deploying. They now resolve siblings
relative to themselves, and a test enforces that.

Consuming them through this package also removes a network fetch from every
job. Cloning them per job made CI depend on a forge that rate-limits SSH, which
failed builds intermittently.

The executable `scripts/resource_preflight.sh` guards intensive local commands
against active Linux memory pressure. The executable
`scripts/phoenix_test_database_preflight.sh` requires linked worktrees to use a
stable `MIX_TEST_PARTITION` and verifies that partition's test database before
the test command starts. They remain at these public paths so application Mix
aliases can share the checks without copying them.
`scripts/intensive_command_lock.sh` serializes resource-heavy local commands
with `flock` on Linux and an atomic-directory fallback on macOS; callers may
choose immediate refusal or bounded operator-visible waiting.

## Ansible roles

Reusable infrastructure roles live under `priv/ansible/roles` so both Mix
dependency consumers and repositories that pin this project as a submodule use
the same provider-neutral implementation. The package includes `common`,
`phoenix_postgres`, `phoenix_blue_green`, `web`, `phoenix_backup`, and
`system_toolbox_identity`.

### Deployment lifecycle hook

The `phoenix_blue_green` role can call an optional consumer-owned executable
configured with `deploy_lifecycle_hook`. It sends `begin-deployment` before
shared migrations, then `deployment-complete` after verified cutover or
`deployment-aborted` when the deploy fails. A failed begin hook aborts before
migration; terminal hooks are best-effort because cutover may already have
occurred.

The hook receives the event as its first argument and the same value in
`CI_CD_DEPLOYMENT_EVENT`. Deployment ID, release ID, pipeline ID, environment,
current and target colors, and an expiry epoch are available through
`CI_CD_DEPLOYMENT_*` variables. Consumers must make quiescence expire no later
than `CI_CD_DEPLOYMENT_EXPIRES_AT_EPOCH`; terminal events may clear it earlier.
The contract does not require a shared filesystem marker.

## Environment badging

Non-production deployments should say so. See
[`docs/environment_badging.md`](docs/environment_badging.md) for the logo
sticker, the per-environment favicon and its cache-busting trap, and the
`X-Robots-Tag` the `web` role emits when `app_is_production` is false.

## GitLab adapter

GitLab consumers can include the tagged public adapter directly:

```yaml
include:
  - remote: "https://git.agile-u.com/olivierg/ci-cd-harness/raw/tag/v0.4.34/templates/gitlab/permit.yml"
  - remote: "https://git.agile-u.com/olivierg/ci-cd-harness/raw/tag/v0.4.34/templates/gitlab/acceptance.yml"
  - remote: "https://git.agile-u.com/olivierg/ci-cd-harness/raw/tag/v0.4.34/templates/gitlab/cd.yml"
  - remote: "https://git.agile-u.com/olivierg/ci-cd-harness/raw/tag/v0.4.34/templates/gitlab/quality.yml"
```

The adapter is deliberately thin: it defines GitLab's job graph and variable
mapping, then fetches the same tag and runs the provider-neutral scripts under
`priv/core`. Pin the include URL and `CI_CD_HARNESS_REF` to the same release.

## Status

Extracted from Agile-U's Forgejo delivery scripts, which remain in that
repository until it migrates onto this package. Until then the logic exists in
two places; close that before a third consumer appears.

## System-toolbox infrastructure role

The package also ships the provider-neutral Ansible role at
`priv/ansible/roles/system_toolbox_identity`. Infrastructure repositories keep
their host inventory and rollout decisions, add this directory to
`roles_path`, and opt in one host with
`system_toolbox_dedicated_user_enabled: true`.

The role migrates an already deployed system-toolbox checkout from the deploy
user's service to a locked `system-toolbox` system identity. It synchronizes
the controller's selected source and dependencies under that identity, installs only
the toolbox's root-owned maintenance helper and sudoers policy, preserves
deploy-user source synchronization through ACLs, grants the identity only
execute traversal on otherwise-private source parents, verifies the new `/health`
service-manager identity, and restores the legacy service automatically when
that verification fails. Exact privileged system units and deploy-user units
remain consumer-owned allowlists.
# Retention policies

The reusable Phoenix roles provide tiered retention for database/file
snapshots and immutable releases. Consumers must set the policy explicitly
after budgeting the entire physical host, including every co-located app,
legacy release tree, logs, caches, and enough working space to create the next
snapshot or unpack the next release. See
[`docs/retention.md`](docs/retention.md).

## GitHub mirror

Forgejo `olivierg/ci-cd-harness` is the canonical repository. GitHub
`ogourment/github-ci-cd-harness` is a push mirror so GitHub consumers can call
the reusable workflows under `.github/workflows`. Develop and release only
from the canonical repository; mirror commits and tags must resolve to the
same objects.
