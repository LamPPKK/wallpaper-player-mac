#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  printf '%s\n' "usage: $0 /path/to/arm64-runtime /path/to/x86_64-runtime /path/to/output" >&2
  exit 64
fi

ARM_DIR="$(cd "$1" && pwd)"
INTEL_DIR="$(cd "$2" && pwd)"
OUTPUT="$3"
OUTPUT_PARENT="$(cd "$(dirname "$OUTPUT")" && pwd)"
case "$OUTPUT" in
  ""|"/"|"$HOME")
    printf '%s\n' "Refusing unsafe renderer runtime output: $OUTPUT" >&2
    exit 1
    ;;
esac

ARM_LIST="$(mktemp)"
INTEL_LIST="$(mktemp)"
ARM_LINKS="$(mktemp)"
INTEL_LINKS="$(mktemp)"
STAGING="$(mktemp -d "$OUTPUT_PARENT/.background-engine-universal-renderer.XXXXXX")"
cleanup() {
  rm -f "$ARM_LIST" "$INTEL_LIST" "$ARM_LINKS" "$INTEL_LINKS"
  [ ! -d "$STAGING" ] || rm -rf "$STAGING"
}
trap cleanup EXIT

(cd "$ARM_DIR" && find . -type f -print | sort) > "$ARM_LIST"
(cd "$INTEL_DIR" && find . -type f -print | sort) > "$INTEL_LIST"
if ! cmp -s "$ARM_LIST" "$INTEL_LIST"; then
  printf '%s\n' "Renderer runtime file sets differ between architectures." >&2
  diff -u "$ARM_LIST" "$INTEL_LIST" || true
  exit 1
fi

(cd "$ARM_DIR" && find . -type l -print | sort) > "$ARM_LINKS"
(cd "$INTEL_DIR" && find . -type l -print | sort) > "$INTEL_LINKS"
if ! cmp -s "$ARM_LINKS" "$INTEL_LINKS"; then
  printf '%s\n' "Renderer runtime symlink sets differ between architectures." >&2
  diff -u "$ARM_LINKS" "$INTEL_LINKS" || true
  exit 1
fi

while IFS= read -r relative; do
  relative="${relative#./}"
  arm="$ARM_DIR/$relative"
  intel="$INTEL_DIR/$relative"
  destination="$STAGING/$relative"
  mkdir -p "$(dirname "$destination")"
  if file "$arm" | rg -q 'Mach-O'; then
    lipo "$arm" -verify_arch arm64
    lipo "$intel" -verify_arch x86_64
    lipo -create "$arm" "$intel" -output "$destination"
    lipo "$destination" -verify_arch arm64 x86_64
    codesign --force --sign - "$destination"
  else
    cmp "$arm" "$intel"
    cp "$arm" "$destination"
  fi
done < "$ARM_LIST"

while IFS= read -r relative; do
  relative="${relative#./}"
  arm_target="$(readlink "$ARM_DIR/$relative")"
  intel_target="$(readlink "$INTEL_DIR/$relative")"
  if [ "$arm_target" != "$intel_target" ]; then
    printf '%s\n' "Renderer runtime symlink targets differ: $relative" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$STAGING/$relative")"
  ln -s "$arm_target" "$STAGING/$relative"
done < "$ARM_LINKS"

chmod +x "$STAGING/background-engine-scene-renderer"
[ ! -e "$OUTPUT" ] || rm -rf "$OUTPUT"
mv "$STAGING" "$OUTPUT"
rm -f "$ARM_LIST" "$INTEL_LIST" "$ARM_LINKS" "$INTEL_LINKS"
trap - EXIT
printf '%s\n' "$OUTPUT"
