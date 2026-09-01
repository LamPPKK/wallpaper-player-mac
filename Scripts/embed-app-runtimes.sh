#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -ne 4 ]; then
  printf '%s\n' \
    "usage: $0 RESOURCES_DIR FFMPEG_RUNTIME_DIR RENDERER_RUNTIME_DIR ARCHS_STRING" >&2
  exit 64
fi

be_require_tools find lipo otool awk sort tr mktemp cp chmod mv dirname basename mkdir rm codesign file

resolve_existing_directory() {
  if [ "$#" -ne 2 ]; then
    return 64
  fi
  local requested="$1"
  local description="$2"
  case "$requested" in
    ""|"/"|"."|".."|"$HOME"|*/./*|*/../*|*/.|*/..)
      printf '%s\n' "Refusing unsafe $description: $requested" >&2
      return 1
      ;;
  esac
  if [ "${requested#/}" = "$requested" ] || [ ! -d "$requested" ] || [ -L "$requested" ]; then
    printf '%s\n' "$description is missing or unsafe: $requested" >&2
    return 1
  fi
  (cd "$requested" && pwd -P)
}

path_contains() {
  case "$2" in
    "$1"|"$1"/*) return 0 ;;
    *) return 1 ;;
  esac
}

RESOURCES="$(resolve_existing_directory "$1" "app Resources directory")"
FFMPEG_RUNTIME="$(resolve_existing_directory "$2" "FFmpeg runtime directory")"
RENDERER_RUNTIME="$(resolve_existing_directory "$3" "Scene renderer runtime directory")"
ARCHS_STRING="$4"

APP_CONTENTS="$(dirname "$RESOURCES")"
APP_ROOT="$(dirname "$APP_CONTENTS")"
if [ "$(basename "$RESOURCES")" != "Resources" ] \
    || [ "$(basename "$APP_CONTENTS")" != "Contents" ]; then
  printf '%s\n' \
    "Refusing app runtime destination outside an app Contents/Resources directory: $RESOURCES" >&2
  exit 1
fi
case "$(basename "$APP_ROOT")" in
  *.app) ;;
  *)
    printf '%s\n' \
      "Refusing app runtime destination outside an .app bundle: $RESOURCES" >&2
    exit 1
    ;;
esac
if [ ! -d "$APP_CONTENTS" ] || [ -L "$APP_CONTENTS" ] \
    || [ ! -d "$APP_ROOT" ] || [ -L "$APP_ROOT" ]; then
  printf '%s\n' "Refusing unsafe app bundle destination: $RESOURCES" >&2
  exit 1
fi
if path_contains "$RESOURCES" "$FFMPEG_RUNTIME" \
    || path_contains "$FFMPEG_RUNTIME" "$RESOURCES" \
    || path_contains "$RESOURCES" "$RENDERER_RUNTIME" \
    || path_contains "$RENDERER_RUNTIME" "$RESOURCES"; then
  printf '%s\n' "Runtime sources and app Resources destination must not contain one another." >&2
  exit 1
fi

ARCHITECTURES=()
HAS_ARM64=0
HAS_X86_64=0
for architecture in $ARCHS_STRING; do
  case "$architecture" in
    arm64) HAS_ARM64=1 ;;
    x86_64) HAS_X86_64=1 ;;
    *)
      printf '%s\n' "Unsupported app runtime architecture: $architecture" >&2
      exit 1
      ;;
  esac
  for existing_architecture in "${ARCHITECTURES[@]:-}"; do
    if [ "$existing_architecture" = "$architecture" ]; then
      printf '%s\n' "Duplicate app runtime architecture: $architecture" >&2
      exit 1
    fi
  done
  ARCHITECTURES+=("$architecture")
done
if [ "${#ARCHITECTURES[@]}" -eq 0 ]; then
  printf '%s\n' "At least one app runtime architecture is required." >&2
  exit 1
fi
# The app's bundled-renderer resolver always requires a Universal runtime,
# including a native-only Debug app. Do not confuse the app's active ARCHS
# with the independently built renderer artifact's architecture contract.
RENDERER_ARCHITECTURES_VALUE="arm64,x86_64"

for managed_name in MediaTools FFmpeg-Source Renderers; do
  managed_path="$RESOURCES/$managed_name"
  if { [ -e "$managed_path" ] || [ -L "$managed_path" ]; } \
      && { [ ! -d "$managed_path" ] || [ -L "$managed_path" ]; }; then
    printf '%s\n' "Refusing unsafe existing app runtime destination: $managed_path" >&2
    exit 1
  fi
done

/bin/bash "$ROOT/Scripts/verify-ffmpeg-runtime.sh" \
  "$FFMPEG_RUNTIME" "${ARCHITECTURES[@]}"
/bin/bash "$ROOT/Scripts/verify-renderer-runtime.sh" \
  "$RENDERER_RUNTIME" arm64 x86_64

STAGING="$(mktemp -d "$RESOURCES/.background-engine-runtime-stage.XXXXXX")"
BACKUP="$(mktemp -d "$RESOURCES/.background-engine-runtime-backup.XXXXXX")"
COMMITTED=0
HAD_ORIGINAL=(0 0 0)
INSTALLED=(0 0 0)
MANAGED_NAMES=(MediaTools FFmpeg-Source Renderers)

cleanup() {
  local cleanup_status="$?"
  local cleanup_index
  local cleanup_name
  local cleanup_target
  local restore_failed=0
  set +e
  if [ "$COMMITTED" -ne 1 ]; then
    cleanup_index=2
    while [ "$cleanup_index" -ge 0 ]; do
      cleanup_name="${MANAGED_NAMES[$cleanup_index]}"
      cleanup_target="$RESOURCES/$cleanup_name"
      if [ "${INSTALLED[$cleanup_index]}" -eq 1 ] \
          && { [ -e "$cleanup_target" ] || [ -L "$cleanup_target" ]; }; then
        if ! rm -rf "$cleanup_target"; then
          printf '%s\n' "Unable to remove incomplete app runtime during rollback: $cleanup_target" >&2
          restore_failed=1
        fi
      fi
      if [ "${HAD_ORIGINAL[$cleanup_index]}" -eq 1 ]; then
        if [ ! -d "$BACKUP/$cleanup_name" ]; then
          printf '%s\n' "Original app runtime is missing from rollback backup: $BACKUP/$cleanup_name" >&2
          restore_failed=1
        elif [ -e "$cleanup_target" ] || [ -L "$cleanup_target" ]; then
          printf '%s\n' "Cannot restore app runtime while its replacement remains; original retained in: $BACKUP/$cleanup_name" >&2
          restore_failed=1
        elif ! mv "$BACKUP/$cleanup_name" "$cleanup_target"; then
          printf '%s\n' "Unable to restore original app runtime: $cleanup_target" >&2
          restore_failed=1
        fi
      fi
      cleanup_index=$((cleanup_index - 1))
    done
  fi
  [ ! -d "$STAGING" ] || rm -rf "$STAGING"
  if [ "$restore_failed" -eq 0 ]; then
    [ ! -d "$BACKUP" ] || rm -rf "$BACKUP"
  else
    printf '%s\n' "Runtime rollback was incomplete; recover original runtime directories from: $BACKUP" >&2
  fi
  return "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cp -R "$FFMPEG_RUNTIME/MediaTools" "$STAGING/MediaTools"
cp -R "$FFMPEG_RUNTIME/Source" "$STAGING/FFmpeg-Source"
mkdir "$STAGING/Renderers"
cp -R "$RENDERER_RUNTIME/." "$STAGING/Renderers/"

chmod 755 "$STAGING/MediaTools/ffmpeg" "$STAGING/MediaTools/ffprobe" \
  "$STAGING/Renderers/background-engine-scene-renderer"

if [ -n "${RUNTIME_SIGN_IDENTITY:-}" ]; then
  while IFS= read -r staged_file; do
    if /usr/bin/file "$staged_file" | /usr/bin/grep -Eq 'Mach-O'; then
      if [ "$RUNTIME_SIGN_IDENTITY" = "-" ]; then
        codesign --force --options runtime --sign "$RUNTIME_SIGN_IDENTITY" "$staged_file"
      else
        codesign --force --options runtime --timestamp \
          --sign "$RUNTIME_SIGN_IDENTITY" "$staged_file"
      fi
    fi
  done < <(find "$STAGING" -type f -print)
  /bin/bash "$ROOT/Scripts/write-renderer-build-manifest.sh" \
    "$STAGING/Renderers" "$RENDERER_ARCHITECTURES_VALUE" \
    --refresh-after-signing >/dev/null
fi

STAGED_FFMPEG="$STAGING/ffmpeg-runtime"
mkdir "$STAGED_FFMPEG"
mv "$STAGING/MediaTools" "$STAGED_FFMPEG/MediaTools"
mv "$STAGING/FFmpeg-Source" "$STAGED_FFMPEG/Source"
/bin/bash "$ROOT/Scripts/verify-ffmpeg-runtime.sh" \
  "$STAGED_FFMPEG" "${ARCHITECTURES[@]}"
/bin/bash "$ROOT/Scripts/verify-renderer-runtime.sh" \
  "$STAGING/Renderers" arm64 x86_64
mv "$STAGED_FFMPEG/MediaTools" "$STAGING/MediaTools"
mv "$STAGED_FFMPEG/Source" "$STAGING/FFmpeg-Source"
rmdir "$STAGED_FFMPEG"

index=0
while [ "$index" -lt 3 ]; do
  name="${MANAGED_NAMES[$index]}"
  target="$RESOURCES/$name"
  if [ -d "$target" ]; then
    mv "$target" "$BACKUP/$name"
    HAD_ORIGINAL[index]=1
  fi
  mv "$STAGING/$name" "$target"
  INSTALLED[index]=1
  index=$((index + 1))
done

COMMITTED=1
rm -rf "$BACKUP"
rm -rf "$STAGING"
trap - EXIT HUP INT TERM
printf '%s\n' "Embedded verified app runtimes in: $RESOURCES"
