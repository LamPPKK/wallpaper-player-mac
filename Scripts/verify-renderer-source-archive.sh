#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  printf '%s\n' \
    "usage: $0 /path/to/wallpaperengine-mac-renderer-source.tar.gz [expected-source-root]" >&2
  exit 64
fi

be_require_tools /usr/bin/tar /usr/bin/grep /usr/bin/perl mktemp rm dirname basename

ARCHIVE="$1"
EXPECTED_SOURCE="${2:-$ROOT/ExternalRenderers/wallpaperengine-mac-renderer}"
if [ ! -f "$ARCHIVE" ] || [ -L "$ARCHIVE" ]; then
  printf '%s\n' "Renderer source archive is missing or unsafe: $ARCHIVE" >&2
  exit 1
fi
if [ ! -d "$EXPECTED_SOURCE" ] || [ -L "$EXPECTED_SOURCE" ]; then
  printf '%s\n' "Expected renderer source is missing or unsafe: $EXPECTED_SOURCE" >&2
  exit 1
fi
EXPECTED_SOURCE="$(cd "$EXPECTED_SOURCE" && pwd -P)"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/background-engine-renderer-source.XXXXXX")"
LISTING="$(mktemp "${TMPDIR:-/tmp}/background-engine-renderer-source-list.XXXXXX")"
cleanup() {
  [ ! -d "$STAGING" ] || rm -rf "$STAGING"
  [ ! -f "$LISTING" ] || rm -f "$LISTING"
}
trap cleanup EXIT

if ! /usr/bin/tar -tzf "$ARCHIVE" > "$LISTING"; then
  printf '%s\n' "Renderer source archive cannot be listed: $ARCHIVE" >&2
  exit 1
fi
if [ ! -s "$LISTING" ] \
    || /usr/bin/grep -Ev '^wallpaperengine-mac-renderer(/|$)' "$LISTING" >/dev/null \
    || /usr/bin/grep -E '(^|/)\.\.(/|$)|^/' "$LISTING" >/dev/null; then
  printf '%s\n' "Renderer source archive contains an unsafe or non-canonical path: $ARCHIVE" >&2
  exit 1
fi

/usr/bin/tar -xzf "$ARCHIVE" -C "$STAGING" --no-same-owner
EXTRACTED_SOURCE="$STAGING/wallpaperengine-mac-renderer"
if [ ! -d "$EXTRACTED_SOURCE" ] || [ -L "$EXTRACTED_SOURCE" ]; then
  printf '%s\n' "Renderer source archive did not extract one safe source root: $ARCHIVE" >&2
  exit 1
fi

EXPECTED_PROVENANCE="$(/usr/bin/perl "$ROOT/Scripts/renderer-source-fingerprint.pl" \
  "$EXPECTED_SOURCE")"
ARCHIVED_PROVENANCE="$(/usr/bin/perl "$ROOT/Scripts/renderer-source-fingerprint.pl" \
  "$EXTRACTED_SOURCE")"
if [ "$ARCHIVED_PROVENANCE" != "$EXPECTED_PROVENANCE" ]; then
  printf '%s\n' \
    "Renderer source archive provenance does not match the current canonical source: $ARCHIVE" >&2
  exit 1
fi

printf '%s\n' "Verified renderer source archive provenance: $ARCHIVE"
