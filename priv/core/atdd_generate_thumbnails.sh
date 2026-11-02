#!/usr/bin/env bash
set -euo pipefail

evidence_dir="${1:?Evidence directory required}"
screenshots_dir="${evidence_dir%/}/screenshots"
thumbnails_dir="${evidence_dir%/}/thumbnails"
stats_file="${ATDD_THUMBNAIL_STATS_FILE:-}"
cache_dir="${ATDD_THUMBNAIL_CACHE_DIR:-_build/test/atdd-thumbnail-cache}"
started_at="${SECONDS}"

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

file_size() {
  if stat -c '%s' -- "$1" >/dev/null 2>&1; then
    stat -c '%s' -- "$1"
  else
    stat -f '%z' -- "$1"
  fi
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d ' ' -f 1
  else
    shasum -a 256 | cut -d ' ' -f 1
  fi
}

# Include the actual renderer and all output settings, not just the source.
# Cache contents are derived files only; evidence originals are never replaced.
thumbnail_options=(-thumbnail '480x>' -strip -quality 70)
renderer_key="$(printf '%s\n' 'thumbnail-cache-v1' "${converter}" \
  "$("${converter}" -version)" "${thumbnail_options[@]}" 'webp' | checksum)"
mkdir -p "${thumbnails_dir}" "${cache_dir}/${renderer_key}"
temporary=""
stats_temporary=""
cache_temporary=""
cleanup() {
  if [[ -n "${temporary}" ]]; then
    rm -f -- "${temporary}"
  fi
  if [[ -n "${stats_temporary}" ]]; then
    rm -f -- "${stats_temporary}"
  fi
  if [[ -n "${cache_temporary}" ]]; then
    rm -f -- "${cache_temporary}" "${cache_temporary}.sha256"
  fi
}
trap cleanup EXIT

thumbnail_count=0
source_bytes=0
thumbnail_bytes=0
rendered_count=0
cache_hit_count=0
while IFS= read -r -d '' screenshot; do
  filename="${screenshot##*/}"
  thumbnail="${thumbnails_dir}/${filename%.png}.webp"
  temporary="$(mktemp "${thumbnails_dir}/.${filename%.png}.tmp.XXXXXX.webp")"
  source_key="$(checksum < "${screenshot}")"
  cached="${cache_dir}/${renderer_key}/${source_key}.webp"
  cache_hit=false

  # A width-only geometry preserves the full-page aspect ratio. The trailing
  # `>` prevents small screenshots from being enlarged.
  if [[ -s "${cached}" && -f "${cached}.sha256" ]] &&
    [[ "$(checksum < "${cached}")" == "$(cat "${cached}.sha256")" ]]; then
    cp -- "${cached}" "${temporary}"
    cache_hit=true
    cache_hit_count=$((cache_hit_count + 1))
  elif ! "${converter}" "${screenshot}" \
    "${thumbnail_options[@]}" \
    "${temporary}"; then
    echo "ATDD thumbnail generation failed: ${screenshot}" >&2
    exit 1
  else
    rendered_count=$((rendered_count + 1))
  fi

  if [[ ! -s "${temporary}" ]]; then
    echo "ATDD thumbnail converter produced an empty file: ${screenshot}" >&2
    exit 1
  fi

  # Atomic publication lets concurrent jobs safely share a cache. A partial or
  # damaged entry is a miss and is regenerated, never accepted by filename.
  if [[ "${cache_hit}" == false ]]; then
    cache_temporary="$(mktemp "${cached}.tmp.XXXXXX")"
    cp -- "${temporary}" "${cache_temporary}"
    checksum < "${cache_temporary}" > "${cache_temporary}.sha256"
    mv -f -- "${cache_temporary}" "${cached}"
    mv -f -- "${cache_temporary}.sha256" "${cached}.sha256"
    cache_temporary=""
  fi

  mv -f -- "${temporary}" "${thumbnail}"
  temporary=""
  thumbnail_count=$((thumbnail_count + 1))
  source_bytes=$((source_bytes + $(file_size "${screenshot}")))
  thumbnail_bytes=$((thumbnail_bytes + $(file_size "${thumbnail}")))
done < <(find "${screenshots_dir}" -maxdepth 1 -type f -name '*.png' -print0)

saved_bytes=$((source_bytes - thumbnail_bytes))
duration_seconds=$((SECONDS - started_at))

if [[ -n "${stats_file}" ]]; then
  mkdir -p -- "$(dirname -- "${stats_file}")"
  stats_temporary="$(mktemp "${stats_file}.tmp.XXXXXX")"
  {
    printf 'ATDD_THUMBNAIL_COUNT=%s\n' "${thumbnail_count}"
    printf 'ATDD_THUMBNAIL_RENDERED_COUNT=%s\n' "${rendered_count}"
    printf 'ATDD_THUMBNAIL_CACHE_HIT_COUNT=%s\n' "${cache_hit_count}"
    printf 'ATDD_THUMBNAIL_SOURCE_BYTES=%s\n' "${source_bytes}"
    printf 'ATDD_THUMBNAIL_BYTES=%s\n' "${thumbnail_bytes}"
    printf 'ATDD_THUMBNAIL_SAVED_BYTES=%s\n' "${saved_bytes}"
    printf 'ATDD_THUMBNAIL_DURATION_SECONDS=%s\n' "${duration_seconds}"
  } > "${stats_temporary}"
  mv -f -- "${stats_temporary}" "${stats_file}"
  stats_temporary=""
fi

printf 'ATDD thumbnail metrics count=%s rendered=%s cache_hits=%s source_bytes=%s thumbnail_bytes=%s saved_bytes=%s duration_seconds=%s\n' \
  "${thumbnail_count}" "${rendered_count}" "${cache_hit_count}" "${source_bytes}" "${thumbnail_bytes}" "${saved_bytes}" "${duration_seconds}"
