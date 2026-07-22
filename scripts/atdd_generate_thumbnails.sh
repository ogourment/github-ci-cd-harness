#!/usr/bin/env bash
set -euo pipefail

evidence_dir="${1:?Evidence directory required}"
screenshots_dir="${evidence_dir%/}/screenshots"
thumbnails_dir="${evidence_dir%/}/thumbnails"

if [[ ! -d "${screenshots_dir}" ]]; then
  echo "ATDD screenshot directory does not exist: ${screenshots_dir}" >&2
  exit 1
fi

if [[ -n "${ATDD_THUMBNAIL_CONVERTER:-}" ]]; then
  converter="${ATDD_THUMBNAIL_CONVERTER}"
elif command -v magick >/dev/null 2>&1; then
  converter="magick"
elif command -v convert >/dev/null 2>&1; then
  converter="convert"
else
  echo "ATDD thumbnail generation requires ImageMagick (magick or convert)" >&2
  exit 1
fi

if ! command -v "${converter}" >/dev/null 2>&1; then
  echo "ATDD thumbnail converter does not exist: ${converter}" >&2
  exit 1
fi

mkdir -p "${thumbnails_dir}"
temporary=""
cleanup() {
  if [[ -n "${temporary}" ]]; then
    rm -f -- "${temporary}"
  fi
}
trap cleanup EXIT

while IFS= read -r -d '' screenshot; do
  filename="${screenshot##*/}"
  thumbnail="${thumbnails_dir}/${filename%.png}.webp"
  temporary="$(mktemp "${thumbnails_dir}/.${filename%.png}.tmp.XXXXXX.webp")"

  # A width-only geometry preserves the full-page aspect ratio. The trailing
  # `>` prevents small screenshots from being enlarged.
  if ! "${converter}" "${screenshot}" \
    -thumbnail '480x>' \
    -strip \
    -quality 70 \
    "${temporary}"; then
    echo "ATDD thumbnail generation failed: ${screenshot}" >&2
    exit 1
  fi

  if [[ ! -s "${temporary}" ]]; then
    echo "ATDD thumbnail converter produced an empty file: ${screenshot}" >&2
    exit 1
  fi

  mv -f -- "${temporary}" "${thumbnail}"
  temporary=""
done < <(find "${screenshots_dir}" -maxdepth 1 -type f -name '*.png' -print0)
