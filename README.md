# ci_cd_harness

Provider-neutral CI/CD delivery for Elixir applications, consumed as a tagged
git dependency.

## Why this exists

`gitlab-ci-cd-harness` is shared through GitLab's `include: project:file:ref`,
which Forgejo has no equivalent for. Rather than copy its scripts into each
application — leaving several divergent implementations of the same delivery
logic — the shared behaviour moves here and is versioned through `mix.lock`,
with the same immutability a pinned tag gave the GitLab harness.

The name carries no forge, deliberately. `gitlab-ci-cd-harness` was the wrong
name the moment a second forge appeared, and `forgejo-ci-cd-harness` would
repeat the mistake.

## Design

Forge-specific code is thin. An adapter answers three questions — what commit,
what run, and where do artifacts live — and everything downstream is written
once against the normalized answers:

```text
lib/ci_cd_harness.ex          forge detection and normalization
lib/mix/tasks/cd.*.ex         provider-neutral entry points
priv/core/                    shared shell, identical on every forge
priv/forges/forgejo/          adapter scripts, where shell is the right tool
```

`priv/core/acceptance_evidence.sh` runs the acceptance suite, builds the
evidence site, evaluates the gate and writes the notification message. It is the
GitLab template's logic verbatim, with one input made explicit:
`ACCEPTANCE_REPORT_URL`, because each forge addresses run artifacts differently.
Evidence is produced even when scenarios fail — the gate is a separate step.

`CiCdHarness.normalized_env/0` maps Forgejo's GitHub-compatible variables onto
the `CI_*` names the existing deployment shell already understands. That is the
seam that lets proven scripts run unchanged under a new forge instead of being
rewritten.

## Usage

```elixir
{:ci_cd_harness, git: "git@git.agile-u.com:olivierg/ci-cd-harness.git", tag: "v0.2.0", only: [:dev, :test], runtime: false}
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
`mix deps.get` reach private dependencies — including this package. It therefore
cannot arrive *as* this package. Applications keep a copy in their own
repository and run it as their first CI step; everything after `deps.get` comes
from here.

## Status

Extracted from Agile-U's Forgejo delivery scripts, which remain in that
repository until it migrates onto this package. Until then the logic exists in
two places; close that before a third consumer appears.
