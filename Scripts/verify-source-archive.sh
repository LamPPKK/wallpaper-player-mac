#!/usr/bin/env bash
set -euo pipefail

readonly archive_path="${1:-}"
readonly tar_tool="/usr/bin/tar"
readonly grep_tool="/usr/bin/grep"
readonly mktemp_tool="/usr/bin/mktemp"
readonly rm_tool="/bin/rm"

if [ -z "$archive_path" ]; then
  printf '%s\n' "Usage: $0 <source-archive.tar.gz>" >&2
  exit 64
fi
if [ ! -f "$archive_path" ]; then
  printf 'Source archive does not exist: %s\n' "$archive_path" >&2
  exit 66
fi
for required_tool in "$tar_tool" "$grep_tool" "$mktemp_tool" "$rm_tool"; do
  if [ ! -x "$required_tool" ]; then
    printf 'Required tool is unavailable: %s\n' "$required_tool" >&2
    exit 69
  fi
done

listing_path="$("$mktemp_tool" "${TMPDIR:-/tmp}/background-engine-source-list.XXXXXX")"
matches_path="$("$mktemp_tool" "${TMPDIR:-/tmp}/background-engine-source-matches.XXXXXX")"
cleanup() {
  "$rm_tool" -f "$listing_path" "$matches_path"
}
trap cleanup EXIT

"$tar_tool" -tzf "$archive_path" > "$listing_path"

readonly personal_xcode_pattern='(^|/)(xcuserdata|[^/]+\.xcuserdatad)(/|$)|(^|/)[^/]+\.xcuserstate$|(^|/)xcschememanagement\.plist$'
if "$grep_tool" -E "$personal_xcode_pattern" "$listing_path" > "$matches_path"; then
  printf '%s\n' 'Source archive contains personal Xcode state:' >&2
  while IFS= read -r match; do
    printf '  %s\n' "$match" >&2
  done < "$matches_path"
  exit 1
fi

printf 'Verified source archive contains no personal Xcode state: %s\n' "$archive_path"
