#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"
be_require_tools find awk

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: verify-lively-resource-bundle.sh <SwiftPM resource bundle>" >&2
  exit 64
fi

RESOURCE_BUNDLE="$1"
FLAT_COLLECTION="$RESOURCE_BUNDLE/LivelyWallpapers"
MACOS_COLLECTION="$RESOURCE_BUNDLE/Contents/Resources/LivelyWallpapers"
LIVELY_WALLPAPER_DIR=""
LAYOUT_COUNT=0

for candidate in "$FLAT_COLLECTION" "$MACOS_COLLECTION"; do
  if [ -L "$candidate" ]; then
    printf '%s\n' "Bundled Lively collection path must not be a symlink: $candidate" >&2
    exit 1
  fi
done

if [ -d "$FLAT_COLLECTION" ]; then
  LIVELY_WALLPAPER_DIR="$FLAT_COLLECTION"
  LAYOUT_COUNT=$((LAYOUT_COUNT + 1))
fi
if [ -d "$MACOS_COLLECTION" ]; then
  LIVELY_WALLPAPER_DIR="$MACOS_COLLECTION"
  LAYOUT_COUNT=$((LAYOUT_COUNT + 1))
fi
if [ "$LAYOUT_COUNT" -ne 1 ]; then
  printf '%s\n' "Resource bundle must contain exactly one supported LivelyWallpapers layout: $RESOURCE_BUNDLE" >&2
  exit 1
fi
if [ ! -f "$LIVELY_WALLPAPER_DIR/catalog.json" ] || [ -L "$LIVELY_WALLPAPER_DIR/catalog.json" ]; then
  printf '%s\n' "Bundled Lively catalog is missing or unsafe: $LIVELY_WALLPAPER_DIR/catalog.json" >&2
  exit 1
fi

UNSAFE_ENTRY="$(find "$LIVELY_WALLPAPER_DIR" -mindepth 1 ! -type f ! -type d | awk 'NR == 1 { first = $0 } END { print first }')"
if [ -n "$UNSAFE_ENTRY" ]; then
  printf '%s\n' "Bundled Lively collection contains an unsafe filesystem entry: $UNSAFE_ENTRY" >&2
  exit 1
fi

for wallpaper_id in lively-the-hill lively-periodic-table lively-parallax lively-music-tv; do
  wallpaper_dir="$LIVELY_WALLPAPER_DIR/$wallpaper_id"
  if [ ! -d "$wallpaper_dir" ] || [ -L "$wallpaper_dir" ]; then
    printf '%s\n' "Required bundled Lively wallpaper is missing or unsafe: $wallpaper_id" >&2
    exit 1
  fi
done

LIVELY_DIRECTORY_COUNT="$(find "$LIVELY_WALLPAPER_DIR" -mindepth 1 -maxdepth 1 -type d | awk 'END { print NR }')"
if [ "$LIVELY_DIRECTORY_COUNT" -ne 4 ]; then
  printf '%s\n' "Bundled Lively collection must contain exactly four wallpaper directories." >&2
  exit 1
fi
LIVELY_TOP_LEVEL_COUNT="$(find "$LIVELY_WALLPAPER_DIR" -mindepth 1 -maxdepth 1 | awk 'END { print NR }')"
if [ "$LIVELY_TOP_LEVEL_COUNT" -ne 5 ]; then
  printf '%s\n' "Bundled Lively collection must contain only its catalog and four wallpaper directories." >&2
  exit 1
fi

printf '%s\n' "$LIVELY_WALLPAPER_DIR"
