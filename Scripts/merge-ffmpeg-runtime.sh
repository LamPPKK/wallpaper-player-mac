#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -ne 3 ]; then
  printf '%s\n' "usage: $0 /path/to/arm64-runtime /path/to/x86_64-runtime /path/to/output" >&2
  exit 64
fi

be_require_tools cmp lipo otool awk mktemp cp chmod mv dirname basename mkdir rm

OUTPUT="$(be_resolve_new_output "$3" "FFmpeg runtime")"
PARENT="$(dirname "$OUTPUT")"
ARM64="$(cd "$1" && pwd -P)"
X86_64="$(cd "$2" && pwd -P)"
STAGING="$(mktemp -d "$PARENT/.background-engine-ffmpeg-runtime.XXXXXX")"
cleanup() { [ ! -d "$STAGING" ] || rm -rf "$STAGING"; }
trap cleanup EXIT

for binary in ffmpeg ffprobe; do
  test -x "$ARM64/MediaTools/$binary"
  test -x "$X86_64/MediaTools/$binary"
done
cmp "$ARM64/Source/ffmpeg-9.0.1.tar.xz" "$X86_64/Source/ffmpeg-9.0.1.tar.xz"

mkdir -p "$STAGING/MediaTools"
cp -R "$ARM64/Source" "$STAGING/Source"
for binary in ffmpeg ffprobe; do
  lipo -create \
    "$ARM64/MediaTools/$binary" \
    "$X86_64/MediaTools/$binary" \
    -output "$STAGING/MediaTools/$binary"
  chmod 755 "$STAGING/MediaTools/$binary"
  lipo "$STAGING/MediaTools/$binary" -verify_arch arm64 x86_64
  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      *)
        printf '%s\n' "$binary contains a non-system dependency: $dependency" >&2
        exit 1
        ;;
    esac
  done < <(otool -L "$STAGING/MediaTools/$binary" | awk '$2 == "(compatibility" { print $1 }')
done
printf '%s\n' "Architectures: arm64 x86_64" >> "$STAGING/Source/build-flags.txt"

if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
  printf '%s\n' "Refusing to overwrite existing FFmpeg runtime: $OUTPUT" >&2
  exit 1
fi
mv "$STAGING" "$OUTPUT"
trap - EXIT
printf '%s\n' "$OUTPUT"
