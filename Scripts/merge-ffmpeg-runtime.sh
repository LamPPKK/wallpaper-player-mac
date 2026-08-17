#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  printf '%s\n' "usage: $0 /path/to/arm64-runtime /path/to/x86_64-runtime /path/to/output" >&2
  exit 64
fi

ARM64="$1"
X86_64="$2"
OUTPUT="$3"
PARENT="$(cd "$(dirname "$OUTPUT")" && pwd)"
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
  if otool -L "$STAGING/MediaTools/$binary" | tail -n +2 | rg -q '(/opt/homebrew|/usr/local)/'; then
    printf '%s\n' "$binary contains a build-machine-only dependency." >&2
    exit 1
  fi
done
printf '%s\n' "Architectures: arm64 x86_64" >> "$STAGING/Source/build-flags.txt"

if [ -e "$OUTPUT" ]; then
  printf '%s\n' "Refusing to overwrite existing FFmpeg runtime: $OUTPUT" >&2
  exit 1
fi
mv "$STAGING" "$OUTPUT"
trap - EXIT
printf '%s\n' "$OUTPUT"
