#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -ne 3 ]; then
  printf '%s\n' "Usage: $0 <source-directory> <volume-name> <output.dmg>" >&2
  exit 64
fi

SOURCE_DIR="$1"
VOLUME_NAME="$2"
REQUESTED_OUTPUT="$3"
HDIUTIL_BIN="${BACKGROUND_ENGINE_HDIUTIL:-/usr/bin/hdiutil}"
MAX_ATTEMPTS="${BACKGROUND_ENGINE_DMG_MAX_ATTEMPTS:-4}"
RETRY_DELAY_SECONDS="${BACKGROUND_ENGINE_DMG_RETRY_DELAY_SECONDS:-2}"

be_require_tools "$HDIUTIL_BIN" mktemp dirname rm ln sleep cat

if [ ! -d "$SOURCE_DIR" ]; then
  printf '%s\n' "DMG source directory does not exist: $SOURCE_DIR" >&2
  exit 1
fi
if [ -z "$VOLUME_NAME" ]; then
  printf '%s\n' "DMG volume name must not be empty." >&2
  exit 64
fi
case "$MAX_ATTEMPTS" in
  ''|*[!0-9]*)
    printf '%s\n' "BACKGROUND_ENGINE_DMG_MAX_ATTEMPTS must be an integer from 1 through 8." >&2
    exit 64
    ;;
esac
if [ "$MAX_ATTEMPTS" -lt 1 ] || [ "$MAX_ATTEMPTS" -gt 8 ]; then
  printf '%s\n' "BACKGROUND_ENGINE_DMG_MAX_ATTEMPTS must be an integer from 1 through 8." >&2
  exit 64
fi
case "$RETRY_DELAY_SECONDS" in
  ''|*[!0-9]*)
    printf '%s\n' "BACKGROUND_ENGINE_DMG_RETRY_DELAY_SECONDS must be an integer from 0 through 30." >&2
    exit 64
    ;;
esac
if [ "$RETRY_DELAY_SECONDS" -gt 30 ]; then
  printf '%s\n' "BACKGROUND_ENGINE_DMG_RETRY_DELAY_SECONDS must be an integer from 0 through 30." >&2
  exit 64
fi

OUTPUT_PATH="$(be_resolve_new_output "$REQUESTED_OUTPUT" "DMG")"
OUTPUT_PARENT="$(dirname "$OUTPUT_PATH")"
WORK_DIR="$(mktemp -d "$OUTPUT_PARENT/.background-engine-dmg.XXXXXX")"

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

attempt=1
delay="$RETRY_DELAY_SECONDS"
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  candidate="$WORK_DIR/attempt-$attempt.dmg"
  standard_output="$WORK_DIR/attempt-$attempt.stdout"
  standard_error="$WORK_DIR/attempt-$attempt.stderr"

  if "$HDIUTIL_BIN" create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$SOURCE_DIR" \
    -nospotlight \
    -format UDZO \
    "$candidate" >"$standard_output" 2>"$standard_error"; then
    if [ ! -s "$candidate" ]; then
      printf '%s\n' "hdiutil reported success without creating a non-empty DMG." >&2
      exit 1
    fi
    if "$HDIUTIL_BIN" verify "$candidate" >>"$standard_output" 2>>"$standard_error"; then
      # The temporary image lives beside the final output, so a hard link makes
      # publication atomic and fails instead of replacing a concurrently-created
      # artifact.
      ln "$candidate" "$OUTPUT_PATH"
      rm "$candidate"
      printf '%s\n' "$OUTPUT_PATH"
      exit 0
    else
      status=$?
    fi
  else
    status=$?
  fi

  cat "$standard_output" >&2
  cat "$standard_error" >&2
  if ! /usr/bin/grep -Eiq 'resource busy' "$standard_error" || [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    exit "$status"
  fi

  printf '%s\n' \
    "hdiutil resource contention on attempt $attempt of $MAX_ATTEMPTS; retrying." >&2
  sleep "$delay"
  if [ "$delay" -lt 30 ]; then
    delay=$((delay * 2))
    if [ "$delay" -gt 30 ]; then
      delay=30
    fi
  fi
  attempt=$((attempt + 1))
done

exit 1
