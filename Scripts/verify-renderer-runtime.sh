#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -lt 2 ]; then
  printf '%s\n' "usage: $0 /path/to/renderer-runtime arch [arch ...]" >&2
  exit 64
fi

be_require_tools file find lipo otool awk codesign readlink dirname basename

RUNTIME="$(cd "$1" && pwd -P)"
shift
RENDERER="$RUNTIME/background-engine-scene-renderer"
LIBRARY_ROOT="$RUNTIME/lib"
DEPENDENCY_LOCK="$RUNTIME/dependencies.lock.tsv"
if [ ! -x "$RENDERER" ] || [ -L "$RENDERER" ]; then
  printf '%s\n' "Renderer is missing or not executable: $RENDERER" >&2
  exit 1
fi
if [ ! -d "$LIBRARY_ROOT" ] || [ -L "$LIBRARY_ROOT" ]; then
  printf '%s\n' "Renderer library root is missing or unsafe: $LIBRARY_ROOT" >&2
  exit 1
fi

while IFS= read -r entry; do
  case "$entry" in
    "$RENDERER")
      [ -f "$entry" ] && [ ! -L "$entry" ] || {
        printf '%s\n' "Renderer executable must be a regular file: $entry" >&2
        exit 1
      }
      ;;
    "$LIBRARY_ROOT")
      ;;
    "$DEPENDENCY_LOCK")
      [ -s "$entry" ] && [ ! -L "$entry" ] || {
        printf '%s\n' "Renderer dependency lock must be a non-empty regular file: $entry" >&2
        exit 1
      }
      ;;
    "$LIBRARY_ROOT"/*)
      if [ "$(dirname "$entry")" != "$LIBRARY_ROOT" ] \
          || { [ ! -f "$entry" ] && [ ! -L "$entry" ]; }; then
        printf '%s\n' "Renderer runtime contains an unsupported library entry: $entry" >&2
        exit 1
      fi
      ;;
    *)
      printf '%s\n' "Renderer runtime contains an unexpected entry: $entry" >&2
      exit 1
      ;;
  esac
done < <(find "$RUNTIME" -mindepth 1 -print)

MACHO_FILES=("$RENDERER")
while IFS= read -r library; do
  if ! /usr/bin/file "$library" | /usr/bin/grep -Eq 'Mach-O'; then
    printf '%s\n' "Renderer runtime library is not Mach-O: $library" >&2
    exit 1
  fi
  MACHO_FILES+=("$library")
done < <(find "$LIBRARY_ROOT" -type f -print)

if ! /usr/bin/file "$RENDERER" | /usr/bin/grep -Eq 'Mach-O'; then
  printf '%s\n' "Renderer executable is not Mach-O: $RENDERER" >&2
  exit 1
fi

MACHO_COUNT=0
for file_path in "${MACHO_FILES[@]}"; do
  MACHO_COUNT=$((MACHO_COUNT + 1))

  for architecture in "$@"; do
    lipo "$file_path" -verify_arch "$architecture"

    case "$file_path" in
      "$RUNTIME/lib/"*)
        relative="${file_path#"$RUNTIME"/lib/}"
        identifier="$(otool -arch "$architecture" -D "$file_path" \
          | awk 'NR > 1 && NF { print; exit }')"
        expected_identifier="@executable_path/lib/$relative"
        if [ "$identifier" != "$expected_identifier" ]; then
          printf '%s\n' "Renderer dylib install ID is not canonical: $file_path [$architecture] -> $identifier" >&2
          exit 1
        fi
        ;;
    esac

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

    deployment_records="$(otool -arch "$architecture" -l "$file_path" | awk '
      function flushDeployment() {
        if (command == "LC_BUILD_VERSION" && minimum != "") {
          # Older otool prints the Mach-O platform enum (1) while newer
          # toolchains may print its symbolic MACOS name.
          print (platform == "1" ? "MACOS" : platform) "\t" minimum
        } else if (command == "LC_VERSION_MIN_MACOSX" && minimum != "") {
          print "MACOS\t" minimum
        }
      }
      $1 == "cmd" {
        flushDeployment()
        command = $2
        platform = ""
        minimum = ""
        next
      }
      command == "LC_BUILD_VERSION" && $1 == "platform" { platform = $2; next }
      command == "LC_BUILD_VERSION" && $1 == "minos" { minimum = $2; next }
      command == "LC_VERSION_MIN_MACOSX" && $1 == "version" { minimum = $2; next }
      END { flushDeployment() }
    ')"
    minimum_count="$(printf '%s\n' "$deployment_records" | awk 'NF { count += 1 } END { print count + 0 }')"
    deployment_platform="$(printf '%s\n' "$deployment_records" | awk 'NF { print $1; exit }')"
    minimum_macos="$(printf '%s\n' "$deployment_records" | awk 'NF { print $2; exit }')"
    if [ "$minimum_count" -ne 1 ] \
        || [ "$deployment_platform" != "MACOS" ] \
        || ! printf '%s\n' "$minimum_macos" \
          | /usr/bin/grep -Eq '^[0-9]+([.][0-9]+){0,2}$'; then
      printf '%s\n' \
        "Renderer Mach-O has an invalid macOS platform or deployment target: $file_path [$architecture]" >&2
      exit 1
    fi
    if ! awk -v actual="$minimum_macos" -v maximum="14.0" 'BEGIN {
        actualCount = split(actual, actualParts, ".")
        maximumCount = split(maximum, maximumParts, ".")
        count = actualCount > maximumCount ? actualCount : maximumCount
        for (componentIndex = 1; componentIndex <= count; componentIndex += 1) {
          actualPart = componentIndex <= actualCount ? actualParts[componentIndex] + 0 : 0
          maximumPart = componentIndex <= maximumCount ? maximumParts[componentIndex] + 0 : 0
          if (actualPart < maximumPart) exit 0
          if (actualPart > maximumPart) exit 1
        }
        exit 0
      }'; then
      printf '%s\n' \
        "Renderer Mach-O requires macOS $minimum_macos, above the supported 14.0 target: $file_path [$architecture]" >&2
      exit 1
    fi
  done

  codesign --verify --strict "$file_path"
done

while IFS= read -r link_path; do
  if [ "$(dirname "$link_path")" != "$RUNTIME/lib" ]; then
    printf '%s\n' "Renderer runtime symlink is outside its library root: $link_path" >&2
    exit 1
  fi
  target="$(readlink "$link_path")"
  case "$target" in
    ""|/*|.|..|*/*)
      printf '%s\n' "Renderer runtime symlink has an unsafe target: $link_path -> $target" >&2
      exit 1
      ;;
  esac
  if [ ! -f "$RUNTIME/lib/$target" ] || [ -L "$RUNTIME/lib/$target" ]; then
    printf '%s\n' "Renderer runtime symlink target is not a regular bundled library: $link_path -> $target" >&2
    exit 1
  fi
done < <(find "$RUNTIME" -type l -print)

if [ "$MACHO_COUNT" -eq 0 ]; then
  printf '%s\n' "Renderer runtime contains no Mach-O files: $RUNTIME" >&2
  exit 1
fi

if [ -f "$RUNTIME/lib/libSDL2-2.0.0.dylib" ] && [ ! -e "$RUNTIME/lib/libSDL3.dylib" ]; then
  printf '%s\n' "Renderer sdl2-compat runtime is missing libSDL3.dylib." >&2
  exit 1
fi

printf '%s\n' "Verified renderer runtime: $RUNTIME"
