#!/usr/bin/env bash
set -euo pipefail

mode="${1:?usage: release_tag.sh preflight|publish}"

case "$mode" in
  preflight|publish) ;;
  *)
    echo "Unsupported release tag mode: $mode" >&2
    exit 2
    ;;
esac

: "${CI_CD_RELEASE_VERSION_COMMAND:?CI_CD_RELEASE_VERSION_COMMAND is required}"
: "${CI_CD_RELEASE_TAG_PREFIX:=v}"
: "${CI_COMMIT_SHA:?CI_COMMIT_SHA is required}"

version="$(bash -lc "$CI_CD_RELEASE_VERSION_COMMAND")"

if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Release version must be strict SemVer MAJOR.MINOR.PATCH; got: $version" >&2
  exit 1
fi

tag="${CI_CD_RELEASE_TAG_PREFIX}${version}"

if ! printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Release tag must be strict vMAJOR.MINOR.PATCH; got: $tag" >&2
  exit 1
fi

git fetch --tags origin

tag_commit() {
  git rev-list -n 1 "refs/tags/$tag" 2>/dev/null || true
}

existing_commit="$(tag_commit)"

if [[ -n "$existing_commit" ]]; then
  if [[ "$existing_commit" == "$CI_COMMIT_SHA" ]]; then
    echo "Release tag already identifies this commit: $tag"
    exit 0
  fi

  echo "Release tag $tag already identifies $existing_commit, not $CI_COMMIT_SHA." >&2
  echo "Bump the application version before deploying this commit." >&2
  exit 1
fi

if [[ "$mode" == "preflight" ]]; then
  echo "Release tag is available: $tag"
  exit 0
fi

: "${CI_REPOSITORY_URL:?CI_REPOSITORY_URL is required when publishing a release tag}"

git config user.name "${CI_CD_RELEASE_TAGGER_NAME:-GitLab CI release}"
git config user.email "${CI_CD_RELEASE_TAGGER_EMAIL:-release@gitlab-ci.invalid}"
git remote set-url origin "$CI_REPOSITORY_URL"
git tag -a "$tag" "$CI_COMMIT_SHA" -m "${CI_CD_RELEASE_TAG_MESSAGE:-Release $tag}"

if git push origin "refs/tags/$tag"; then
  echo "Published release tag: $tag"
  exit 0
fi

# A concurrent retry may have published the same tag between preflight and
# push. Accept only that exact idempotent outcome; preserve every real conflict.
git tag -d "$tag" >/dev/null 2>&1 || true
git fetch --tags origin
existing_commit="$(tag_commit)"

if [[ "$existing_commit" == "$CI_COMMIT_SHA" ]]; then
  echo "Release tag was concurrently published for this commit: $tag"
  exit 0
fi

echo "Failed to publish release tag: $tag" >&2
exit 1
