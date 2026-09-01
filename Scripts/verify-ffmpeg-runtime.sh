#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -lt 2 ]; then
  printf '%s\n' "usage: $0 /path/to/ffmpeg-runtime arch [arch ...]" >&2
  exit 64
fi

be_require_tools file find lipo otool awk sort tr codesign dirname basename

RUNTIME_INPUT="$1"
shift
case "$RUNTIME_INPUT" in
  ""|"/"|"."|".."|*/./*|*/../*|*/.|*/..)
    printf '%s\n' "Refusing unsafe FFmpeg runtime: $RUNTIME_INPUT" >&2
    exit 1
    ;;
esac
if [ "${RUNTIME_INPUT#/}" = "$RUNTIME_INPUT" ] \
    || [ ! -d "$RUNTIME_INPUT" ] \
    || [ -L "$RUNTIME_INPUT" ]; then
  printf '%s\n' "FFmpeg runtime is missing or unsafe: $RUNTIME_INPUT" >&2
  exit 1
fi
RUNTIME="$(cd "$RUNTIME_INPUT" && pwd -P)"

REQUESTED_ARCHITECTURES=()
for architecture in "$@"; do
  case "$architecture" in
    arm64|x86_64) ;;
    *)
      printf '%s\n' "Unsupported FFmpeg runtime architecture: $architecture" >&2
      exit 1
      ;;
  esac
  for existing_architecture in "${REQUESTED_ARCHITECTURES[@]:-}"; do
    if [ "$existing_architecture" = "$architecture" ]; then
      printf '%s\n' "Duplicate FFmpeg runtime architecture: $architecture" >&2
      exit 1
    fi
  done
  REQUESTED_ARCHITECTURES+=("$architecture")
done

MEDIA_TOOLS="$RUNTIME/MediaTools"
SOURCE_ROOT="$RUNTIME/Source"
FFMPEG="$MEDIA_TOOLS/ffmpeg"
FFPROBE="$MEDIA_TOOLS/ffprobe"
SOURCE_ARCHIVE="$SOURCE_ROOT/ffmpeg-9.0.1.tar.xz"
SOURCE_LICENSE="$SOURCE_ROOT/FFmpeg-LICENSE.md"
BUILD_FLAGS="$SOURCE_ROOT/build-flags.txt"

for directory in "$MEDIA_TOOLS" "$SOURCE_ROOT"; do
  if [ ! -d "$directory" ] || [ -L "$directory" ]; then
    printf '%s\n' "FFmpeg runtime directory is missing or unsafe: $directory" >&2
    exit 1
  fi
done
for binary in "$FFMPEG" "$FFPROBE"; do
  if [ ! -f "$binary" ] || [ -L "$binary" ] || [ ! -x "$binary" ]; then
    printf '%s\n' "FFmpeg runtime executable is missing or unsafe: $binary" >&2
    exit 1
  fi
done
for source_file in "$SOURCE_ARCHIVE" "$SOURCE_LICENSE" "$BUILD_FLAGS"; do
  if [ ! -s "$source_file" ] || [ -L "$source_file" ]; then
    printf '%s\n' "FFmpeg source disclosure is missing or unsafe: $source_file" >&2
    exit 1
  fi
done

while IFS= read -r entry; do
  case "$entry" in
    "$MEDIA_TOOLS"|"$SOURCE_ROOT")
      [ -d "$entry" ] && [ ! -L "$entry" ] || {
        printf '%s\n' "FFmpeg runtime contains an unsafe directory: $entry" >&2
        exit 1
      }
      ;;
    "$FFMPEG"|"$FFPROBE"|"$SOURCE_ARCHIVE"|"$SOURCE_LICENSE"|"$BUILD_FLAGS")
      [ -f "$entry" ] && [ ! -L "$entry" ] || {
        printf '%s\n' "FFmpeg runtime contains an unsafe file: $entry" >&2
        exit 1
      }
      ;;
    *)
      printf '%s\n' "FFmpeg runtime contains an unexpected entry: $entry" >&2
      exit 1
      ;;
  esac
done < <(find "$RUNTIME" -mindepth 1 -print)

RUNTIME_ARCHITECTURES=""
for binary in "$FFMPEG" "$FFPROBE"; do
  if ! /usr/bin/file "$binary" | /usr/bin/grep -Eq 'Mach-O'; then
    printf '%s\n' "FFmpeg runtime executable is not Mach-O: $binary" >&2
    exit 1
  fi
  ACTUAL_ARCHITECTURES="$(lipo -archs "$binary" | tr ' ' '\n' | sort | awk 'NF { if (value != "") value = value " "; value = value $0 } END { print value }')"
  case "$ACTUAL_ARCHITECTURES" in
    arm64|x86_64|"arm64 x86_64") ;;
    *)
      printf '%s\n' \
        "FFmpeg runtime executable has unsupported architecture slices: $binary ($ACTUAL_ARCHITECTURES)" >&2
      exit 1
      ;;
  esac
  if [ -z "$RUNTIME_ARCHITECTURES" ]; then
    RUNTIME_ARCHITECTURES="$ACTUAL_ARCHITECTURES"
  elif [ "$ACTUAL_ARCHITECTURES" != "$RUNTIME_ARCHITECTURES" ]; then
    printf '%s\n' \
      "FFmpeg and FFprobe architecture slices do not match: $ACTUAL_ARCHITECTURES versus $RUNTIME_ARCHITECTURES" >&2
    exit 1
  fi
  for architecture in "${REQUESTED_ARCHITECTURES[@]}"; do
    lipo "$binary" -verify_arch "$architecture"
    while IFS= read -r dependency; do
      [ -n "$dependency" ] || continue
      case "$dependency" in
        /System/Library/*|/usr/lib/*) ;;
        *)
          printf '%s\n' \
            "FFmpeg runtime executable contains a non-system dependency: $binary [$architecture] -> $dependency" >&2
          exit 1
          ;;
        esac
      done < <(otool -arch "$architecture" -L "$binary" | awk '$2 == "(compatibility" { print $1 }')

    deployment_records="$(otool -arch "$architecture" -l "$binary" | awk '
      function flushDeployment() {
        if (command == "LC_BUILD_VERSION" && minimum != "") {
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
        "FFmpeg Mach-O has an invalid macOS platform or deployment target: $binary [$architecture]" >&2
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
        "FFmpeg Mach-O requires macOS $minimum_macos, above the supported 14.0 target: $binary [$architecture]" >&2
      exit 1
    fi
  done
done

if ! /usr/bin/grep -Eq '^Build-ID:[[:space:]]+ffmpeg-9[.]0[.]1-background-engine-1[[:space:]]*$' "$BUILD_FLAGS"; then
  printf '%s\n' "FFmpeg runtime has an unexpected or missing build ID: $BUILD_FLAGS" >&2
  exit 1
fi
DECLARED_ARCHITECTURES="$(awk '/^Architectures:/ { for (i = 2; i <= NF; i += 1) print $i }' "$BUILD_FLAGS" | sort | awk 'NF { if (value != "") value = value " "; value = value $0 } END { print value }')"
if [ "$DECLARED_ARCHITECTURES" != "$RUNTIME_ARCHITECTURES" ]; then
  printf '%s\n' \
    "FFmpeg runtime metadata does not match its executable slices: $DECLARED_ARCHITECTURES (expected $RUNTIME_ARCHITECTURES)" >&2
  exit 1
fi

if ! "$FFMPEG" -hide_banner -version 2>&1 \
    | /usr/bin/grep -Eq '^ffmpeg version 9[.]0[.]1([^0-9.]|$)'; then
  printf '%s\n' "FFmpeg runtime is not FFmpeg 9.0.1: $FFMPEG" >&2
  exit 1
fi
if ! "$FFPROBE" -hide_banner -version 2>&1 \
    | /usr/bin/grep -Eq '^ffprobe version 9[.]0[.]1([^0-9.]|$)'; then
  printf '%s\n' "FFmpeg runtime is not FFprobe 9.0.1: $FFPROBE" >&2
  exit 1
fi
for binary in "$FFMPEG" "$FFPROBE"; do
  if ! PROTOCOLS_OUTPUT="$("$binary" -hide_banner -protocols 2>&1)"; then
    printf '%s\n' "Unable to inspect FFmpeg runtime protocols: $binary" >&2
    exit 1
  fi
  if printf '%s\n' "$PROTOCOLS_OUTPUT" \
      | /usr/bin/grep -Eq '^[[:space:]]*(concat|http|https|tcp|udp)[[:space:]]*$'; then
    printf '%s\n' "FFmpeg runtime exposes a forbidden local-playback protocol: $binary" >&2
    exit 1
  fi
done

printf '%s\n' "Verified FFmpeg runtime: $RUNTIME"
