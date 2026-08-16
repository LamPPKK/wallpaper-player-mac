#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf '%s\n' "usage: $0 /path/to/wwb-scene-renderer /path/to/output-runtime" >&2
  exit 64
fi

BINARY="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTPUT="$2"
OUTPUT_PARENT="$(cd "$(dirname "$OUTPUT")" && pwd)"

if [ ! -x "$BINARY" ]; then
  printf '%s\n' "Renderer is missing or not executable: $BINARY" >&2
  exit 1
fi
if ! command -v dylibbundler >/dev/null 2>&1; then
  printf '%s\n' "dylibbundler is required (brew install dylibbundler)." >&2
  exit 1
fi
case "$OUTPUT" in
  ""|"/"|"$HOME")
    printf '%s\n' "Refusing unsafe renderer runtime output: $OUTPUT" >&2
    exit 1
    ;;
esac

STAGING="$(mktemp -d "$OUTPUT_PARENT/.background-engine-renderer-runtime.XXXXXX")"
cleanup() { [ ! -d "$STAGING" ] || rm -rf "$STAGING"; }
trap cleanup EXIT

cp "$BINARY" "$STAGING/background-engine-scene-renderer"
chmod +x "$STAGING/background-engine-scene-renderer"
(
  cd "$STAGING"
  dylibbundler -ns -b -cd \
    -x background-engine-scene-renderer \
    -d lib \
    -p '@executable_path/lib/' \
    -s "$(dirname "$BINARY")" \
    -s "$(dirname "$BINARY")/../lib"
)

# Homebrew's sdl2-compat loads SDL3 at runtime rather than declaring it as a
# Mach-O dependency, so dylibbundler cannot discover it recursively.
if command -v brew >/dev/null 2>&1; then
  SDL3_PREFIX="$(brew --prefix sdl3 2>/dev/null || true)"
  SDL3_LIBRARY="$SDL3_PREFIX/lib/libSDL3.0.dylib"
  if [ -n "$SDL3_PREFIX" ] && [ -f "$SDL3_LIBRARY" ]; then
    cp "$SDL3_LIBRARY" "$STAGING/lib/libSDL3.0.dylib"
    chmod +w "$STAGING/lib/libSDL3.0.dylib"
    install_name_tool -id '@executable_path/lib/libSDL3.0.dylib' "$STAGING/lib/libSDL3.0.dylib"
    # sdl2-compat calls dlopen("libSDL3.dylib"). Keep the unversioned name it
    # probes in addition to the versioned Mach-O file shipped by Homebrew.
    ln -s libSDL3.0.dylib "$STAGING/lib/libSDL3.dylib"
  fi
fi

if [ -f "$STAGING/lib/libSDL2-2.0.0.dylib" ] && [ ! -e "$STAGING/lib/libSDL3.dylib" ]; then
  printf '%s\n' "sdl2-compat was bundled, but its SDL3 runtime dependency is missing." >&2
  exit 1
fi

while IFS= read -r file; do
  if otool -L "$file" 2>/dev/null | tail -n +2 | rg -q '^\s+(/usr/local|/opt/homebrew)/'; then
    printf '%s\n' "Renderer still contains a Homebrew-only dependency: $file" >&2
    exit 1
  fi
done < <(find "$STAGING" -type f -print)

# dylibbundler rewrites every original rpath to the requested install path.
# A binary with several original rpaths can therefore end up with duplicate
# LC_RPATH commands, which modern dyld rejects. All dependencies above are
# now explicit @executable_path references, so remove the obsolete rpaths.
while IFS= read -r file; do
  file "$file" | rg -q 'Mach-O' || continue
  if otool -L "$file" | tail -n +2 | rg -q '@rpath/'; then
    printf '%s\n' "Renderer still contains an unresolved @rpath dependency: $file" >&2
    exit 1
  fi
  while rpath="$(otool -l "$file" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2; exit }')" \
      && [ -n "$rpath" ]; do
    install_name_tool -delete_rpath "$rpath" "$file"
  done
  install_name_tool -add_rpath '@executable_path/lib/' "$file"
done < <(find "$STAGING" -type f -print)

# install_name_tool invalidates Homebrew's existing signatures. Re-sign each
# nested Mach-O ad hoc so this thin runtime can be smoke-tested. Release
# packaging replaces these signatures with Developer ID signatures.
while IFS= read -r file; do
  if file "$file" | rg -q 'Mach-O'; then
    codesign --force --sign - "$file"
  fi
done < <(find "$STAGING/lib" -type f -print)
codesign --force --sign - "$STAGING/background-engine-scene-renderer"

[ ! -e "$OUTPUT" ] || rm -rf "$OUTPUT"
mv "$STAGING" "$OUTPUT"
trap - EXIT
printf '%s\n' "$OUTPUT"
