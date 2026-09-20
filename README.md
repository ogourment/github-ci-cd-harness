# ci_cd_harness

Provider-neutral CI/CD delivery for Elixir applications, consumed as a tagged
git dependency.

## GitHub: build once, stage automatically, promote manually

Copy and configure [the CI/staging caller](templates/github/ci.yml) and
[the manual production caller](templates/github/promote-production.yml).
They use the shared Phoenix workflows: no consumer-local deployment script is
needed. Enable `run-acceptance` and your existing test command in the CI caller
when your application has browser acceptance tests.

Push to `main` builds/tests one release, deploys it to staging, verifies its
health identity and public HTML, and uploads a staging-verification receipt.
After reviewing staging, open **Actions → Promote production → Run workflow**,
select `main`, and enter the successful staging CI run's numeric ID from its
`/actions/runs/<id>` URL. This production-only workflow does not rerun CI or
touch staging. It downloads that run's release and receipt, checks repository,
workflow path, main-branch event, successful run/attempt and staging job, then
checks the archive SHA-256, version, release ID and source commit.

Configure the GitHub `production` environment with required reviewers and a
main-branch deployment policy. The workflow uses that environment; approval is
not created automatically by YAML. Its caller must grant `actions: read` and
`contents: write`. Map production SSH secrets explicitly, or define matching
secret names on the protected environment. Configure staging separately.

Both artifacts expire after 14 days. Old runs without a receipt are deliberately
ineligible: adopt this version and complete a fresh staging CI run first.
Missing, expired, failed, PR, wrong-workflow or stale-attempt sources fail closed.
An explicitly selected older eligible run is an intentional rollback; promotion
does not infer "latest" or require it to be the release currently on staging.
The selected commit is checked out before tag preflight and deployment; tag
publication follows successful production health verification. Release health
retains the **source** run identity; the job summary records the separate
promotion run and actor. Production jobs share a non-cancelling concurrency
group (GitHub concurrency is not a FIFO deployment queue).

`phoenix-delivery.yml` still supports combined staging/production delivery for
compatibility. Do not expose its `deploy-production` input as the normal manual
production action: use the separate promotion caller instead. The shared core
still owns SSH/rsync transport, migrations, health verification and release tags;
only GitHub provenance/artifact selection lives in the GitHub adapter.

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
{:ci_cd_harness, git: "https://git.agile-u.com/olivierg/ci-cd-harness.git", tag: "v0.4.44", only: [:dev, :test], runtime: false}
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

### Deployment lifecycle transport

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

### Application-aware drain and fencing

Consumers whose application owns durable or long-running work can opt into
`deploy_application_lifecycle_enabled`. The blue/green role then uses the
configured localhost lifecycle path to drain the old slot, poll until it
reports `safe_to_stop`, fence its ownership, and wait until the candidate
reports active ownership. It never substitutes the legacy fixed sleep for an
application safety decision.

Authentication is supplied through a root-readable curl config file named by
`deploy_application_lifecycle_curl_config`, so bearer credentials do not enter
process arguments or deployment output. If the bounded pre-fence wait expires,
the harness restores the old nginx route, asks the old owner to resume claims,
leaves it alive, and fails the deployment visibly. After fencing, rollback is
not guessed: candidate promotion must succeed before the color is committed.

When release distribution is disabled, set `deploy_lifecycle_state_file` to an
absolute host path readable by the application. The shared deploy service then
writes the deployment ID and bounded expiry before migrations and removes only
its own marker after completion or abort. This host-managed path does not invoke
release RPC and may be used without a consumer hook. `deploy_lifecycle_hook`
remains available for consumers with another supported transport; both may be
enabled when both effects are intentional.

## Environment badging

Non-production deployments should say so. See
[`docs/environment_badging.md`](docs/environment_badging.md) for the logo
sticker, the per-environment favicon and its cache-busting trap, and the
`X-Robots-Tag` the `web` role emits when `app_is_production` is false.

## GitLab adapter

GitLab consumers can include the tagged public adapter directly:

```yaml
include:
  - remote: "https://git.agile-u.com/olivierg/ci-cd-harness/raw/tag/v0.4.44/templates/gitlab/permit.yml"
  - remote: "https://git.agile-u.com/olivierg/ci-cd-harness/raw/tag/v0.4.44/templates/gitlab/acceptance.yml"
  - remote: "https://git.agile-u.com/olivierg/ci-cd-harness/raw/tag/v0.4.44/templates/gitlab/cd.yml"
  - remote: "https://git.agile-u.com/olivierg/ci-cd-harness/raw/tag/v0.4.44/templates/gitlab/quality.yml"
```

The adapter is deliberately thin: it defines GitLab's job graph and variable
mapping, then fetches the same tag and runs the provider-neutral scripts under
`priv/core`. Pin the include URL and `CI_CD_HARNESS_REF` to the same release.
Artifact-producing reusable jobs expire their artifacts after two weeks. GitLab
projects must also disable "Keep artifacts from most recent successful jobs" so
that this maximum applies to the latest successful pipeline on each ref.

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


## Existing TLS certificates

The web role preserves HTTP-01 challenges at /.well-known/acme-challenge/
before the HTTPS redirect or application proxy. For an existing webroot-based
certificate, set certbot_webroot to the path in its renewal configuration
(default /var/www/letsencrypt). Other custom paths are not inferred.
The role enables certbot.timer and reloads nginx after successful renewal of
its certificate, validating configuration first.

After upgrading from 0.4.42 or earlier, review an Ansible web-role dry run and
reapply that role on the consumer host. Then run a certificate-specific
certbot renewal dry run and verify the served expiration date after actual
renewal. Merely updating a Git pin does not change a host.

### Artifact-only acceptance gate

AcceptanceHarness 0.11 supplies a Python standard-library gate reader. The evidence
job retains it as `tmp/atdd/acceptance_gate.py`; the gate job uses that exact reader
when present and otherwise uses the legacy Mix task. Preserve this file when
overriding artifact paths. Upgraded consumers can remove PostgreSQL and Mix
dependency setup from the gate job, but must provide Python 3 and preserve its
evidence dependency and production gating. The evidence-producing job still runs
its selected scenarios once. This optimization does not relax acceptance outcomes.
