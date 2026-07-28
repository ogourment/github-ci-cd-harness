#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/release_tag.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

remote="$tmp_root/remote.git"
work="$tmp_root/work"

git init --bare --quiet "$remote"
git init --quiet "$work"
git -C "$work" config user.name "Release test"
git -C "$work" config user.email "release-test@example.invalid"
printf '0.1.0\n' > "$work/VERSION"
git -C "$work" add VERSION
git -C "$work" commit --quiet -m "Initial release"
git -C "$work" remote add origin "$remote"
git -C "$work" push --quiet -u origin HEAD:main

first_commit="$(git -C "$work" rev-parse HEAD)"

(
  cd "$work"
  CI_CD_RELEASE_VERSION_COMMAND="cat VERSION" \
    CI_COMMIT_SHA="$first_commit" \
    "$script" preflight
  CI_CD_RELEASE_VERSION_COMMAND="cat VERSION" \
    CI_COMMIT_SHA="$first_commit" \
    CI_REPOSITORY_URL="$remote" \
    "$script" publish
  CI_CD_RELEASE_VERSION_COMMAND="cat VERSION" \
    CI_COMMIT_SHA="$first_commit" \
    CI_REPOSITORY_URL="$remote" \
    "$script" publish
)

test "$(git --git-dir="$remote" rev-list -n 1 refs/tags/v0.1.0)" = "$first_commit"

printf 'same version, different commit\n' >> "$work/VERSION"
git -C "$work" add VERSION
git -C "$work" commit --quiet -m "Change without version bump"
second_commit="$(git -C "$work" rev-parse HEAD)"

if (
  cd "$work"
  CI_CD_RELEASE_VERSION_COMMAND="head -n 1 VERSION" \
    CI_COMMIT_SHA="$second_commit" \
    "$script" preflight
); then
  echo "Expected a conflicting release tag to fail preflight" >&2
  exit 1
fi

printf 'release_tag_test: ok\n'
