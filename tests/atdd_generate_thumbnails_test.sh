#!/usr/bin/env bash
set -euo pipefail

test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

evidence_dir="${test_root}/acceptance evidence"
screenshots_dir="${evidence_dir}/screenshots"
bin_dir="${test_root}/bin"
args_log="${test_root}/converter-args"
mkdir -p "${screenshots_dir}/nested" "${bin_dir}"
printf 'png' > "${screenshots_dir}/step one.png"
printf 'png' > "${screenshots_dir}/--shell-safe.png"
newline_name=$'line\nbreak'
printf 'png' > "${screenshots_dir}/${newline_name}.png"
printf 'ignored' > "${screenshots_dir}/nested/nested.png"
printf 'ignored' > "${screenshots_dir}/upper.PNG"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$@" >> "$CONVERTER_ARGS_LOG"' \
  'for output; do :; done' \
  'printf '\''webp\n'\'' > "$output"' \
  > "${bin_dir}/fake-magick"
chmod +x "${bin_dir}/fake-magick"
export CONVERTER_ARGS_LOG="${args_log}"

PATH="${bin_dir}:${PATH}" ATDD_THUMBNAIL_CONVERTER=fake-magick \
  scripts/atdd_generate_thumbnails.sh "${evidence_dir}"

[[ -s "${evidence_dir}/thumbnails/step one.webp" ]]
[[ -s "${evidence_dir}/thumbnails/--shell-safe.webp" ]]
[[ -s "${evidence_dir}/thumbnails/${newline_name}.webp" ]]
[[ ! -e "${evidence_dir}/thumbnails/nested.webp" ]]
[[ ! -e "${evidence_dir}/thumbnails/upper.webp" ]]
grep -Fxq "${screenshots_dir}/step one.png" "${args_log}"
grep -Fxq -- '-thumbnail' "${args_log}"
grep -Fxq '480x>' "${args_log}"
grep -Fxq -- '-strip' "${args_log}"
grep -Fxq -- '-quality' "${args_log}"
grep -Fxq '70' "${args_log}"

# Re-running replaces the same outputs rather than accumulating alternates.
PATH="${bin_dir}:${PATH}" ATDD_THUMBNAIL_CONVERTER=fake-magick \
  scripts/atdd_generate_thumbnails.sh "${evidence_dir}"
[[ "$(find "${evidence_dir}/thumbnails" -type f -name '*.webp' -print0 | tr -cd '\0' | wc -c)" -eq 3 ]]

# Converter failure leaves an existing thumbnail intact and removes temp files.
printf 'previous\n' > "${evidence_dir}/thumbnails/step one.webp"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'for output; do :; done' \
  'printf '\''incomplete\n'\'' > "$output"' \
  'exit 9' \
  > "${bin_dir}/failing-magick"
chmod +x "${bin_dir}/failing-magick"

if PATH="${bin_dir}:${PATH}" ATDD_THUMBNAIL_CONVERTER=failing-magick \
  scripts/atdd_generate_thumbnails.sh "${evidence_dir}" \
  2> "${test_root}/failure-error"; then
  echo "expected a converter failure" >&2
  exit 1
fi

grep -Fxq 'previous' "${evidence_dir}/thumbnails/step one.webp"
if find "${evidence_dir}/thumbnails" -type f -name '.*.tmp.*.webp' | grep -q .; then
  echo "expected failed conversion temporary files to be removed" >&2
  exit 1
fi
grep -Fq 'ATDD thumbnail generation failed:' "${test_root}/failure-error"

if ATDD_THUMBNAIL_CONVERTER=definitely-missing-thumbnail-converter \
  scripts/atdd_generate_thumbnails.sh "${evidence_dir}" \
  2> "${test_root}/missing-converter-error"; then
  echo "expected a missing converter to fail" >&2
  exit 1
fi
grep -Fq 'ATDD thumbnail converter does not exist:' \
  "${test_root}/missing-converter-error"

echo "atdd_generate_thumbnails_test: passed"
