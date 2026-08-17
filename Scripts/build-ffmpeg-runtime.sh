#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="9.0.1"
BUILD_ID="ffmpeg-9.0.1-background-engine-1"
RELEASE_BASE="https://ffmpeg.org/releases"
ARCHIVE_NAME="ffmpeg-${VERSION}.tar.xz"
SIGNING_KEY_URL="https://ffmpeg.org/ffmpeg-devel.asc"
SIGNING_FINGERPRINT="FCF986EA15E6E293A5644F10B4322F04D67658D8"
OUTPUT="${1:-$ROOT/dist/ffmpeg-runtime}"
FFMPEG_ARCHS="${FFMPEG_ARCHS:-arm64 x86_64}"
WORK="$(mktemp -d)"

cleanup() { [ ! -d "$WORK" ] || rm -rf "$WORK"; }
trap cleanup EXIT

for tool in curl gpg tar make clang lipo otool rg; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf '%s\n' "Required build tool is missing: $tool" >&2
    exit 1
  }
done

curl --fail --location --proto '=https' --tlsv1.2 \
  "$RELEASE_BASE/$ARCHIVE_NAME" -o "$WORK/$ARCHIVE_NAME"
curl --fail --location --proto '=https' --tlsv1.2 \
  "$RELEASE_BASE/$ARCHIVE_NAME.asc" -o "$WORK/$ARCHIVE_NAME.asc"
curl --fail --location --proto '=https' --tlsv1.2 \
  "$SIGNING_KEY_URL" -o "$WORK/ffmpeg-devel.asc"

export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --import "$WORK/ffmpeg-devel.asc" >/dev/null 2>&1
ACTUAL_FINGERPRINT="$(gpg --batch --with-colons --fingerprint | awk -F: '$1 == "fpr" {print $10; exit}')"
if [ "$ACTUAL_FINGERPRINT" != "$SIGNING_FINGERPRINT" ]; then
  printf '%s\n' "Unexpected FFmpeg signing-key fingerprint: $ACTUAL_FINGERPRINT" >&2
  exit 1
fi
gpg --batch --verify "$WORK/$ARCHIVE_NAME.asc" "$WORK/$ARCHIVE_NAME"

tar -xf "$WORK/$ARCHIVE_NAME" -C "$WORK"
SOURCE="$WORK/ffmpeg-$VERSION"
COMMON_FLAGS=(
  --prefix=/
  --disable-shared
  --enable-static
  --disable-doc
  --disable-debug
  --disable-devices
  --disable-network
  --disable-autodetect
  --disable-protocols
  --enable-protocol=file,pipe,fd,concat
  --disable-programs
  --enable-ffmpeg
  --enable-ffprobe
  --enable-videotoolbox
  --enable-audiotoolbox
  --enable-avcodec
  --enable-avformat
  --enable-avfilter
  --enable-swscale
  --enable-swresample
)

for architecture in $FFMPEG_ARCHS; do
  BUILD="$WORK/build-$architecture"
  PREFIX="$WORK/prefix-$architecture"
  mkdir -p "$BUILD" "$PREFIX"
  (
    cd "$BUILD"
    "$SOURCE/configure" \
      "${COMMON_FLAGS[@]}" \
      --arch="$architecture" \
      --target-os=darwin \
      --cc=clang \
      --extra-cflags="-arch $architecture -mmacosx-version-min=14.0" \
      --extra-ldflags="-arch $architecture -mmacosx-version-min=14.0" \
      --prefix="$PREFIX"
    make -j"$(sysctl -n hw.logicalcpu)"
    make install
  )
  "$PREFIX/bin/ffmpeg" -hide_banner -version
  "$PREFIX/bin/ffprobe" -hide_banner -version
done

STAGING="$WORK/runtime"
mkdir -p "$STAGING/MediaTools" "$STAGING/Source"
for binary in ffmpeg ffprobe; do
  inputs=()
  for architecture in $FFMPEG_ARCHS; do
    inputs+=("$WORK/prefix-$architecture/bin/$binary")
  done
  if [ "${#inputs[@]}" -eq 1 ]; then
    cp "${inputs[0]}" "$STAGING/MediaTools/$binary"
  else
    lipo -create "${inputs[@]}" -output "$STAGING/MediaTools/$binary"
    lipo "$STAGING/MediaTools/$binary" -verify_arch arm64 x86_64
  fi
  chmod 755 "$STAGING/MediaTools/$binary"
  if otool -L "$STAGING/MediaTools/$binary" | tail -n +2 | rg -q '(/opt/homebrew|/usr/local)/'; then
    printf '%s\n' "$binary contains a build-machine-only dependency." >&2
    exit 1
  fi
done

cp "$WORK/$ARCHIVE_NAME" "$STAGING/Source/"
cp "$SOURCE/LICENSE.md" "$STAGING/Source/FFmpeg-LICENSE.md"
{
  printf 'Build-ID: %s\n' "$BUILD_ID"
  printf 'Source: %s/%s\n' "$RELEASE_BASE" "$ARCHIVE_NAME"
  printf 'Signing-key: %s\n' "$SIGNING_FINGERPRINT"
  printf 'Architectures: %s\n' "$FFMPEG_ARCHS"
  printf 'Configure flags:\n'
  printf '  %s\n' "${COMMON_FLAGS[@]}"
} > "$STAGING/Source/build-flags.txt"

if [ -e "$OUTPUT" ]; then
  printf '%s\n' "Refusing to overwrite existing FFmpeg runtime: $OUTPUT" >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT")"
mv "$STAGING" "$OUTPUT"
printf '%s\n' "$OUTPUT"
