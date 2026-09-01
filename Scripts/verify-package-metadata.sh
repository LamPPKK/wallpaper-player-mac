#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -ne 3 ]; then
  printf '%s\n' "Usage: $0 <Background Engine.app> <marketing-version> <build-number>" >&2
  exit 64
fi

APP_REQUESTED="$1"
EXPECTED_VERSION="$2"
EXPECTED_BUILD="$3"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

be_require_tools dirname basename pwd
if [ ! -x "$PLIST_BUDDY" ]; then
  printf '%s\n' "Required build tool is missing or not executable: $PLIST_BUDDY" >&2
  exit 1
fi

case "$APP_REQUESTED" in
  ""|"/"|"."|".."|"$HOME"|*/./*|*/../*|*/.|*/..)
    printf '%s\n' "Refusing unsafe app bundle path: $APP_REQUESTED" >&2
    exit 1
    ;;
esac
case "$APP_REQUESTED" in
  /*) ;;
  *)
    printf '%s\n' "App bundle path must be absolute: $APP_REQUESTED" >&2
    exit 1
    ;;
esac
if [[ ! "$EXPECTED_VERSION" =~ ^[0-9]+([.][0-9]+)*(-[A-Za-z0-9]+([.][A-Za-z0-9]+)*)?$ ]]; then
  printf '%s\n' "Refusing invalid marketing version: $EXPECTED_VERSION" >&2
  exit 1
fi
if [[ ! "$EXPECTED_BUILD" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "Refusing invalid build number: $EXPECTED_BUILD" >&2
  exit 1
fi

APP_PARENT="$(cd -P "$(dirname "$APP_REQUESTED")" && pwd)"
APP_DIR="$APP_PARENT/$(basename "$APP_REQUESTED")"
if [ ! -d "$APP_DIR" ] || [ -L "$APP_DIR" ]; then
  printf '%s\n' "App bundle is missing, is not a directory, or is a symbolic link: $APP_DIR" >&2
  exit 1
fi
case "$(basename "$APP_DIR")" in
  *.app) ;;
  *)
    printf '%s\n' "Expected an .app bundle: $APP_DIR" >&2
    exit 1
    ;;
esac

verify_bundle_metadata() {
  if [ "$#" -ne 3 ]; then
    printf '%s\n' "verify_bundle_metadata requires a label, bundle path, and bundle identifier." >&2
    return 64
  fi

  local label="$1"
  local bundle="$2"
  local expected_identifier="$3"
  local plist="$bundle/Contents/Info.plist"
  local key
  local expected
  local actual
  local executable
  local executable_dir
  local executable_path

  if [ ! -d "$bundle" ] || [ -L "$bundle" ]; then
    printf '%s\n' "$label bundle is missing, is not a directory, or is a symbolic link: $bundle" >&2
    return 1
  fi
  if [ ! -f "$plist" ] || [ -L "$plist" ]; then
    printf '%s\n' "$label Info.plist is missing, is not a regular file, or is a symbolic link: $plist" >&2
    return 1
  fi

  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
    case "$key" in
      CFBundleIdentifier) expected="$expected_identifier" ;;
      CFBundleShortVersionString) expected="$EXPECTED_VERSION" ;;
      CFBundleVersion) expected="$EXPECTED_BUILD" ;;
    esac
    if ! actual="$("$PLIST_BUDDY" -c "Print :$key" "$plist" 2>/dev/null)"; then
      printf '%s\n' "$label Info.plist is missing required key $key: $plist" >&2
      return 1
    fi
    if [ "$actual" != "$expected" ]; then
      printf '%s\n' "$label $key mismatch: expected '$expected', found '$actual'" >&2
      return 1
    fi
  done

  if ! executable="$("$PLIST_BUDDY" -c "Print :CFBundleExecutable" "$plist" 2>/dev/null)"; then
    printf '%s\n' "$label Info.plist is missing required key CFBundleExecutable: $plist" >&2
    return 1
  fi
  case "$executable" in
    ""|"."|".."|*/*)
      printf '%s\n' "$label CFBundleExecutable must be a safe file name, found '$executable'" >&2
      return 1
      ;;
  esac

  executable_dir="$bundle/Contents/MacOS"
  executable_path="$executable_dir/$executable"
  if [ ! -d "$executable_dir" ] || [ -L "$executable_dir" ]; then
    printf '%s\n' "$label executable directory is missing, is not a directory, or is a symbolic link: $executable_dir" >&2
    return 1
  fi
  if [ ! -f "$executable_path" ] || [ -L "$executable_path" ] || [ ! -x "$executable_path" ]; then
    printf '%s\n' "$label executable is missing, is not a regular executable file, or is a symbolic link: $executable_path" >&2
    return 1
  fi
}

XPC_DIR="$APP_DIR/Contents/XPCServices/BackgroundEngineSteamCMDRunner.xpc"
SAVER_DIR="$APP_DIR/Contents/Resources/Background Engine.saver"
verify_bundle_metadata "App" "$APP_DIR" "com.lamppkk.backgroundengine"
verify_bundle_metadata "SteamCMD XPC" "$XPC_DIR" "com.lamppkk.backgroundengine.steamcmd-runner"
verify_bundle_metadata "Screen saver" "$SAVER_DIR" "com.lamppkk.backgroundengine.screensaver"

printf '%s\n' "Verified package metadata: version $EXPECTED_VERSION ($EXPECTED_BUILD)"
