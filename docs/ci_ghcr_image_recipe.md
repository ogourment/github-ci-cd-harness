# GHCR Elixir/Playwright CI image recipe

Use a prebuilt Elixir/Playwright image for Phoenix acceptance pipelines instead of installing browser dependencies in every job.

## Current Agile-U image

```yaml
default:
  image: "$APP_CI_IMAGE_REGISTRY/ci-elixir-playwright:$APP_CI_IMAGE_TAG"

variables:
  APP_CI_IMAGE_REGISTRY: "ghcr.io/ogourment/agile-u"
  APP_CI_IMAGE_TAG: "elixir-1.18.4-erlang-28.0.1-bookworm-playwright-1.61.1-v1"
  PLAYWRIGHT_BROWSERS_PATH: "/ms-playwright"
  NPM_CONFIG_CACHE: "$CI_PROJECT_DIR/.npm"
```

The image contains:

- Elixir `1.18.4`
- Erlang/OTP `28.0.1`
- Debian Bookworm
- Node.js and npm
- Hex and Rebar
- Playwright `1.61.1`
- Chromium installed under `/ms-playwright`
- common build and Postgres client tools

## Required GitLab/Framagit variable

- `DOCKER_AUTH_CONFIG`: Docker auth JSON allowing the runner to pull the private GHCR image.

Projects that build or publish the image also need:

- `GHCR_USERNAME`
- `GHCR_TOKEN`

## Acceptance job setup

Do not run this in consumers that use the image:

```sh
npx playwright install --with-deps chromium
```

Keep this when the app needs asset dependencies:

```sh
npm ci --prefix assets
```

The app may still use the app-local Playwright CLI when needed, but browser binaries should come from `/ms-playwright`.

## Extra package installs

Keep per-job package installs for app-specific tools that are not part of the image, such as:

- ImageMagick or `librsvg2-bin`
- Firefox, Java, or Selenium
- `rsync`, `openssh-client`, or `python3`
- `jq`

If multiple consuming projects need the same extra tools, create a new shared image tag rather than adding slow package installs to every pipeline.

## Measuring before and after

Use recent comparable pipelines before the image change as the baseline. Prefer pipelines with the same job graph and acceptance template version.

Example Framagit measurement:

```sh
for pipeline_id in 1385126 1385145 1385188; do
  glab api "projects/olivierg%2Fpunnles/pipelines/${pipeline_id}/jobs" |
    jq -r --arg pipeline_id "$pipeline_id" \
      '.[] | select(.duration != null) | [$pipeline_id, .name, .duration] | @tsv'
done
```

Average by job:

```sh
for pipeline_id in 1385126 1385145 1385188; do
  glab api "projects/olivierg%2Fpunnles/pipelines/${pipeline_id}/jobs" |
    jq -r --arg pipeline_id "$pipeline_id" \
      '.[] | select(.duration != null) | [$pipeline_id, .name, .duration] | @tsv'
done |
  jq -R -s '
    split("\n")[:-1]
    | map(split("\t"))
    | group_by(.[1])
    | map({
        job: .[0][1],
        count: length,
        avg_seconds: ((map(.[2] | tonumber) | add / length) * 10 | round / 10)
      })
    | sort_by(.job)
  '
```

After the image change lands, run the same command against the new successful pipelines and compare matching job names.
