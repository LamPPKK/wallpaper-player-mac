#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${ACTION:-}" in
  analyze)
    printf '%s\n' "Skipping app runtime embedding during Analyze."
    exit 0
    ;;
  indexbuild)
    printf '%s\n' "Skipping app runtime embedding during indexing."
    exit 0
    ;;
esac

remove_stale_debug_runtimes() {
  if [ -z "${TARGET_BUILD_DIR:-}" ] \
      || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    return 0
  fi
  local requested="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
  if [ ! -e "$requested" ] && [ ! -L "$requested" ]; then
    return 0
  fi
  case "$requested" in
    ""|"/"|"."|".."|"$HOME"|*/./*|*/../*|*/.|*/..)
      printf '%s\n' "Refusing unsafe Debug app Resources directory: $requested" >&2
      return 1
      ;;
  esac
  if [ "${requested#/}" = "$requested" ] || [ ! -d "$requested" ] || [ -L "$requested" ]; then
    printf '%s\n' "Refusing unsafe Debug app Resources directory: $requested" >&2
    return 1
  fi
  local resources
  local contents
  local app
  resources="$(cd "$requested" && pwd -P)"
  contents="$(dirname "$resources")"
  app="$(dirname "$contents")"
  if [ "$(basename "$resources")" != "Resources" ] \
      || [ "$(basename "$contents")" != "Contents" ] \
      || [ ! -d "$contents" ] \
      || [ -L "$contents" ] \
      || [ ! -d "$app" ] \
      || [ -L "$app" ]; then
    printf '%s\n' "Refusing Debug cleanup outside an app Contents/Resources directory: $resources" >&2
    return 1
  fi
  case "$(basename "$app")" in
    *.app) ;;
    *)
      printf '%s\n' "Refusing Debug cleanup outside an .app bundle: $resources" >&2
      return 1
      ;;
  esac
  local managed_name
  local managed_path
  for managed_name in MediaTools FFmpeg-Source Renderers; do
    managed_path="$resources/$managed_name"
    if [ -e "$managed_path" ] || [ -L "$managed_path" ]; then
      if [ ! -d "$managed_path" ] || [ -L "$managed_path" ]; then
        printf '%s\n' "Refusing unsafe stale Debug runtime: $managed_path" >&2
        return 1
      fi
      rm -rf "$managed_path"
    fi
  done
}

FFMPEG_RUNTIME="${BACKGROUND_ENGINE_FFMPEG_RUNTIME_DIR:-}"
RENDERER_RUNTIME="${BACKGROUND_ENGINE_SCENE_RENDERER_RUNTIME_DIR:-}"
if { [ -n "$FFMPEG_RUNTIME" ] && [ -z "$RENDERER_RUNTIME" ]; } \
    || { [ -z "$FFMPEG_RUNTIME" ] && [ -n "$RENDERER_RUNTIME" ]; }; then
  printf '%s\n' \
    "Both BACKGROUND_ENGINE_FFMPEG_RUNTIME_DIR and BACKGROUND_ENGINE_SCENE_RENDERER_RUNTIME_DIR must be configured together." >&2
  exit 1
fi

if [ -z "$FFMPEG_RUNTIME" ]; then
  if [ "${CONFIGURATION:-}" = "Debug" ] && [ "${ACTION:-build}" = "build" ]; then
    remove_stale_debug_runtimes
    printf '%s\n' \
      "warning: skipping app runtime embedding in Debug because both runtime build settings are unset." >&2
    exit 0
  fi
  printf '%s\n' \
    "Verified FFmpeg and Scene renderer runtimes are required for ${CONFIGURATION:-unknown} ${ACTION:-build}." >&2
  exit 1
fi

for required_name in TARGET_BUILD_DIR UNLOCALIZED_RESOURCES_FOLDER_PATH ARCHS; do
  eval "required_value=\${$required_name:-}"
  if [ -z "$required_value" ]; then
    printf '%s\n' "Required Xcode build setting is missing: $required_name" >&2
    exit 1
  fi
done

RESOURCES_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] \
    && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  export RUNTIME_SIGN_IDENTITY="$EXPANDED_CODE_SIGN_IDENTITY"
else
  unset RUNTIME_SIGN_IDENTITY || true
fi

/bin/bash "$ROOT/Scripts/embed-app-runtimes.sh" \
  "$RESOURCES_DIR" "$FFMPEG_RUNTIME" "$RENDERER_RUNTIME" "$ARCHS"
