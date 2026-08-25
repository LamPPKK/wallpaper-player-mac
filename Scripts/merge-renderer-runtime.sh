#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -ne 3 ]; then
  printf '%s\n' "usage: $0 /path/to/arm64-runtime /path/to/x86_64-runtime /path/to/output" >&2
  exit 64
fi

be_require_tools file find sort cmp diff lipo codesign mktemp cp chmod mv \
  dirname basename readlink mkdir ln rm install_name_tool otool awk sed cat \
  /usr/bin/perl

OUTPUT="$(be_resolve_new_output "$3" "renderer runtime")"
OUTPUT_PARENT="$(dirname "$OUTPUT")"
ARM_DIR="$(cd "$1" && pwd -P)"
INTEL_DIR="$(cd "$2" && pwd -P)"

ARM_LIST="$(mktemp)"
INTEL_LIST="$(mktemp)"
ARM_MAP="$(mktemp)"
INTEL_MAP="$(mktemp)"
ALIASES="$(mktemp)"
ARM_NORMALIZED="$(mktemp -d "$OUTPUT_PARENT/.background-engine-normalized-arm64.XXXXXX")"
INTEL_NORMALIZED="$(mktemp -d "$OUTPUT_PARENT/.background-engine-normalized-x86_64.XXXXXX")"
STAGING="$(mktemp -d "$OUTPUT_PARENT/.background-engine-universal-renderer.XXXXXX")"
cleanup() {
  rm -f "$ARM_LIST" "$INTEL_LIST" "$ARM_MAP" "$INTEL_MAP" "$ALIASES"
  [ ! -d "$ARM_NORMALIZED" ] || rm -rf "$ARM_NORMALIZED"
  [ ! -d "$INTEL_NORMALIZED" ] || rm -rf "$INTEL_NORMALIZED"
  [ ! -d "$STAGING" ] || rm -rf "$STAGING"
}
trap cleanup EXIT

canonical_dylib_name() {
  local original="$1"
  local stem
  case "$original" in
    *.dylib)
      stem="${original%.dylib}"
      while printf '%s\n' "$stem" | /usr/bin/grep -Eq '[.-][0-9]+$'; do
        stem="$(printf '%s\n' "$stem" | sed -E 's/[.-][0-9]+$//')"
      done
      if [ -z "$stem" ]; then
        printf '%s\n' "Cannot derive a canonical renderer library name from: $original" >&2
        return 1
      fi
      printf '%s.dylib\n' "$stem"
      ;;
    *)
      printf '%s\n' "$original"
      ;;
  esac
}

validate_library_name() {
  local name="$1"
  if ! printf '%s\n' "$name" | /usr/bin/grep -Eq '^[[:alnum:]_.+-]+$'; then
    printf '%s\n' "Renderer runtime contains an unsafe library name: $name" >&2
    return 1
  fi
}

normalize_runtime() {
  local runtime="$1"
  local architecture="$2"
  local normalized="$3"
  local mapping="$4"
  local renderer="$runtime/background-engine-scene-renderer"
  local library_dir="$runtime/lib"
  local dependency_lock="$runtime/dependencies.lock.tsv"
  local entry source name canonical destination target canonical_target file dependency old
  local -a rewrite_args

  "$ROOT/Scripts/verify-renderer-runtime.sh" "$runtime" "$architecture" >/dev/null
  if [ ! -d "$library_dir" ]; then
    printf '%s\n' "Renderer runtime library directory is missing: $library_dir" >&2
    return 1
  fi
  while IFS= read -r entry; do
    case "$entry" in
      "$renderer")
        if [ ! -f "$entry" ] || [ -L "$entry" ]; then
          printf '%s\n' "Renderer executable must be a regular file: $entry" >&2
          return 1
        fi
        ;;
      "$library_dir")
        if [ ! -d "$entry" ] || [ -L "$entry" ]; then
          printf '%s\n' "Renderer library root must be a directory: $entry" >&2
          return 1
        fi
        ;;
      "$dependency_lock")
        if [ ! -s "$entry" ] || [ -L "$entry" ]; then
          printf '%s\n' "Renderer dependency lock must be a non-empty regular file: $entry" >&2
          return 1
        fi
        ;;
      "$library_dir"/*)
        if [ "$(dirname "$entry")" != "$library_dir" ] \
            || { [ ! -f "$entry" ] && [ ! -L "$entry" ]; }; then
          printf '%s\n' "Renderer runtime contains an unsupported nested entry: $entry" >&2
          return 1
        fi
        ;;
      *)
        printf '%s\n' "Renderer runtime contains an unexpected entry: $entry" >&2
        return 1
        ;;
    esac
  done < <(find "$runtime" -mindepth 1 -print | sort)

  mkdir -p "$normalized/lib"
  cp "$renderer" "$normalized/background-engine-scene-renderer"
  chmod u+w,+x "$normalized/background-engine-scene-renderer"
  if [ -f "$dependency_lock" ]; then
    cp "$dependency_lock" "$normalized/dependencies.lock.tsv"
  fi
  : > "$mapping"

  while IFS= read -r source; do
    if [ "$(dirname "$source")" != "$library_dir" ]; then
      printf '%s\n' "Renderer runtime contains a nested library: $source" >&2
      return 1
    fi
    name="$(basename "$source")"
    validate_library_name "$name"
    canonical="$(canonical_dylib_name "$name")"
    validate_library_name "$canonical"
    printf '%s\t%s\n' "$name" "$canonical" >> "$mapping"
    destination="$normalized/lib/$canonical"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      if ! cmp -s "$source" "$destination"; then
        printf '%s\n' "Renderer libraries collide after canonicalization: $name -> $canonical" >&2
        return 1
      fi
    else
      cp "$source" "$destination"
      chmod u+w "$destination"
    fi
  done < <(find "$library_dir" -type f -print | sort)

  while IFS= read -r source; do
    if [ "$(dirname "$source")" != "$library_dir" ]; then
      printf '%s\n' "Renderer runtime contains a nested library symlink: $source" >&2
      return 1
    fi
    name="$(basename "$source")"
    target="$(readlink "$source")"
    validate_library_name "$name"
    validate_library_name "$target"
    canonical_target="$(canonical_dylib_name "$target")"
    validate_library_name "$canonical_target"
    if [ ! -f "$normalized/lib/$canonical_target" ]; then
      printf '%s\n' "Renderer library symlink target is missing: $name -> $target" >&2
      return 1
    fi
    printf '%s\t%s\n' "$name" "$canonical_target" >> "$mapping"
  done < <(find "$library_dir" -type l -print | sort)

  sort -u "$mapping" -o "$mapping"
  if ! awk -F '\t' '
      previous[$1] != "" && previous[$1] != $2 { exit 1 }
      { previous[$1] = $2 }
    ' "$mapping"; then
    printf '%s\n' "Renderer library alias maps to more than one canonical dependency." >&2
    return 1
  fi

  while IFS= read -r file; do
    if [ "$file" = "$normalized/dependencies.lock.tsv" ]; then
      continue
    fi
    /usr/bin/file "$file" | /usr/bin/grep -Eq 'Mach-O' || {
      printf '%s\n' "Renderer runtime contains a non-Mach-O library: $file" >&2
      return 1
    }
    rewrite_args=()
    while IFS= read -r dependency; do
      case "$dependency" in
        @executable_path/lib/*)
          old="${dependency#@executable_path/lib/}"
          canonical="$(awk -F '\t' -v name="$old" '$1 == name { print $2; exit }' "$mapping")"
          if [ -z "$canonical" ]; then
            printf '%s\n' "Renderer dependency has no canonical mapping: $file -> $dependency" >&2
            return 1
          fi
          if [ "$old" != "$canonical" ]; then
            rewrite_args+=(
              -change "$dependency" "@executable_path/lib/$canonical"
            )
          fi
          ;;
      esac
    done < <(otool -L "$file" | awk '$2 == "(compatibility" { print $1 }')
    if [ "$(dirname "$file")" = "$normalized/lib" ]; then
      rewrite_args+=(-id "@executable_path/lib/$(basename "$file")")
    fi
    if [ "${#rewrite_args[@]}" -gt 0 ]; then
      install_name_tool "${rewrite_args[@]}" "$file"
    fi
    codesign --force --sign - "$file"
  done < <(find "$normalized" -type f -print | sort)

  while IFS=$'\t' read -r old canonical; do
    [ "$old" != "$canonical" ] || continue
    if [ -e "$normalized/lib/$old" ] || [ -L "$normalized/lib/$old" ]; then
      printf '%s\n' "Renderer library alias collides with a canonical file: $old" >&2
      return 1
    fi
    ln -s "$canonical" "$normalized/lib/$old"
  done < "$mapping"

  "$ROOT/Scripts/verify-renderer-runtime.sh" "$normalized" "$architecture" >/dev/null
}

normalize_runtime "$ARM_DIR" arm64 "$ARM_NORMALIZED" "$ARM_MAP"
normalize_runtime "$INTEL_DIR" x86_64 "$INTEL_NORMALIZED" "$INTEL_MAP"

(cd "$ARM_NORMALIZED" && find . -type f -print | sort) > "$ARM_LIST"
(cd "$INTEL_NORMALIZED" && find . -type f -print | sort) > "$INTEL_LIST"
if ! cmp -s "$ARM_LIST" "$INTEL_LIST"; then
  printf '%s\n' "Renderer runtime logical file sets differ between architectures." >&2
  diff -u "$ARM_LIST" "$INTEL_LIST" || true
  exit 1
fi

while IFS= read -r relative; do
  relative="${relative#./}"
  arm="$ARM_NORMALIZED/$relative"
  intel="$INTEL_NORMALIZED/$relative"
  destination="$STAGING/$relative"
  mkdir -p "$(dirname "$destination")"
  if /usr/bin/file "$arm" | /usr/bin/grep -Eq 'Mach-O'; then
    lipo "$arm" -verify_arch arm64
    lipo "$intel" -verify_arch x86_64
    lipo -create "$arm" "$intel" -output "$destination"
    lipo "$destination" -verify_arch arm64 x86_64
    codesign --force --sign - "$destination"
  else
    if ! cmp -s "$arm" "$intel"; then
      case "$relative" in
        dependencies.lock.tsv)
          printf '%s\n' "Renderer dependency locks differ between architectures." >&2
          ;;
        *)
          printf '%s\n' "Renderer non-Mach-O files differ between architectures: $relative" >&2
          ;;
      esac
      exit 1
    fi
    cp "$arm" "$destination"
  fi
done < "$ARM_LIST"

cat "$ARM_MAP" "$INTEL_MAP" | sort -u > "$ALIASES"
if ! awk -F '\t' '
    previous[$1] != "" && previous[$1] != $2 { exit 1 }
    { previous[$1] = $2 }
  ' "$ALIASES"; then
  printf '%s\n' "Renderer architectures disagree about a library alias target." >&2
  exit 1
fi
while IFS=$'\t' read -r alias canonical; do
  [ "$alias" != "$canonical" ] || continue
  if [ ! -f "$STAGING/lib/$canonical" ]; then
    printf '%s\n' "Canonical renderer library is missing for alias: $alias -> $canonical" >&2
    exit 1
  fi
  if [ -e "$STAGING/lib/$alias" ] || [ -L "$STAGING/lib/$alias" ]; then
    printf '%s\n' "Renderer library alias collides in the Universal runtime: $alias" >&2
    exit 1
  fi
  ln -s "$canonical" "$STAGING/lib/$alias"
done < "$ALIASES"

chmod +x "$STAGING/background-engine-scene-renderer"
"$ROOT/Scripts/verify-renderer-runtime.sh" "$STAGING" arm64 x86_64
/usr/bin/perl -e 'alarm 30; exec @ARGV' \
  "$STAGING/background-engine-scene-renderer" --help >/dev/null

if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
  printf '%s\n' "Refusing to overwrite existing renderer runtime: $OUTPUT" >&2
  exit 1
fi
mv "$STAGING" "$OUTPUT"
rm -f "$ARM_LIST" "$INTEL_LIST" "$ARM_MAP" "$INTEL_MAP" "$ALIASES"
rm -rf "$ARM_NORMALIZED" "$INTEL_NORMALIZED"
trap - EXIT
printf '%s\n' "$OUTPUT"
