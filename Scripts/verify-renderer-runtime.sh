#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -lt 2 ]; then
  printf '%s\n' "usage: $0 /path/to/renderer-runtime arch [arch ...]" >&2
  exit 64
fi

be_require_tools file find lipo otool awk codesign

RUNTIME="$(cd "$1" && pwd -P)"
shift
RENDERER="$RUNTIME/background-engine-scene-renderer"
if [ ! -x "$RENDERER" ]; then
  printf '%s\n' "Renderer is missing or not executable: $RENDERER" >&2
  exit 1
fi

MACHO_COUNT=0
while IFS= read -r file_path; do
  /usr/bin/file "$file_path" | /usr/bin/grep -Eq 'Mach-O' || continue
  MACHO_COUNT=$((MACHO_COUNT + 1))

  for architecture in "$@"; do
    lipo "$file_path" -verify_arch "$architecture"

    while IFS= read -r dependency; do
      [ -n "$dependency" ] || continue
      case "$dependency" in
        /System/Library/*|/usr/lib/*)
          ;;
        @executable_path/lib/*)
          relative="${dependency#@executable_path/lib/}"
          case "$relative" in
            ""|/*|.|..|*/./*|*/../*|*/.|*/..)
              printf '%s\n' "Renderer dependency escapes its runtime: $file_path [$architecture] -> $dependency" >&2
              exit 1
              ;;
          esac
          if [ ! -e "$RUNTIME/lib/$relative" ] && [ ! -L "$RUNTIME/lib/$relative" ]; then
            printf '%s\n' "Renderer dependency is missing: $file_path [$architecture] -> $dependency" >&2
            exit 1
          fi
          ;;
        /opt/homebrew/*|/usr/local/*)
          printf '%s\n' "Renderer contains a Homebrew-only dependency: $file_path [$architecture] -> $dependency" >&2
          exit 1
          ;;
        @rpath/*|@loader_path/*)
          printf '%s\n' "Renderer contains an unresolved dependency: $file_path [$architecture] -> $dependency" >&2
          exit 1
          ;;
        *)
          printf '%s\n' "Renderer contains a non-system external dependency: $file_path [$architecture] -> $dependency" >&2
          exit 1
          ;;
      esac
    done < <(otool -arch "$architecture" -L "$file_path" | awk '$2 == "(compatibility" { print $1 }')

    rpaths="$(otool -arch "$architecture" -l "$file_path" | awk '
      $1 == "cmd" && $2 == "LC_RPATH" { want_path = 1; next }
      want_path && $1 == "path" { print $2; want_path = 0 }
    ')"
    rpath_count="$(printf '%s\n' "$rpaths" | awk 'NF { count += 1 } END { print count + 0 }')"
    if [ "$rpath_count" -ne 1 ] || [ "$rpaths" != "@executable_path/lib/" ]; then
      printf '%s\n' "Renderer Mach-O must contain exactly one @executable_path/lib/ LC_RPATH: $file_path [$architecture]" >&2
      exit 1
    fi
  done

  codesign --verify --strict "$file_path"
done < <(find "$RUNTIME" -type f -print)

if [ "$MACHO_COUNT" -eq 0 ]; then
  printf '%s\n' "Renderer runtime contains no Mach-O files: $RUNTIME" >&2
  exit 1
fi

if [ -f "$RUNTIME/lib/libSDL2-2.0.0.dylib" ] && [ ! -e "$RUNTIME/lib/libSDL3.dylib" ]; then
  printf '%s\n' "Renderer sdl2-compat runtime is missing libSDL3.dylib." >&2
  exit 1
fi

printf '%s\n' "Verified renderer runtime: $RUNTIME"
