#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -lt 2 ]; then
  printf '%s\n' "usage: $0 /path/to/renderer-runtime arch [arch ...]" >&2
  exit 64
fi

be_require_tools file find lipo otool awk sort cmp codesign readlink dirname \
  basename shasum mktemp rm /usr/bin/perl /usr/bin/grep /usr/bin/strings

RUNTIME="$(cd "$1" && pwd -P)"
shift
HAS_ARM64=0
HAS_X86_64=0
for architecture in "$@"; do
  case "$architecture" in
    arm64)
      [ "$HAS_ARM64" -eq 0 ] || {
        printf '%s\n' "Duplicate renderer runtime architecture: arm64" >&2
        exit 64
      }
      HAS_ARM64=1
      ;;
    x86_64)
      [ "$HAS_X86_64" -eq 0 ] || {
        printf '%s\n' "Duplicate renderer runtime architecture: x86_64" >&2
        exit 64
      }
      HAS_X86_64=1
      ;;
    *)
      printf '%s\n' "Unsupported renderer runtime architecture: $architecture" >&2
      exit 64
      ;;
  esac
done
if [ "$HAS_ARM64" -eq 1 ] && [ "$HAS_X86_64" -eq 1 ]; then
  EXPECTED_ARCHITECTURES="arm64,x86_64"
  VERIFY_ARCHITECTURES=(arm64 x86_64)
elif [ "$HAS_ARM64" -eq 1 ]; then
  EXPECTED_ARCHITECTURES="arm64"
  VERIFY_ARCHITECTURES=(arm64)
else
  EXPECTED_ARCHITECTURES="x86_64"
  VERIFY_ARCHITECTURES=(x86_64)
fi

RENDERER="$RUNTIME/background-engine-scene-renderer"
LIBRARY_ROOT="$RUNTIME/lib"
DEPENDENCY_LOCK="$RUNTIME/dependencies.lock.tsv"
BUILD_MANIFEST="$RUNTIME/renderer-build-manifest.tsv"
MACHO_DIGESTS="$RUNTIME/macho-slice-digests.tsv"
if [ ! -x "$RENDERER" ] || [ -L "$RENDERER" ]; then
  printf '%s\n' "Renderer is missing or not executable: $RENDERER" >&2
  exit 1
fi
if [ ! -d "$LIBRARY_ROOT" ] || [ -L "$LIBRARY_ROOT" ]; then
  printf '%s\n' "Renderer library root is missing or unsafe: $LIBRARY_ROOT" >&2
  exit 1
fi
if [ ! -s "$DEPENDENCY_LOCK" ] || [ -L "$DEPENDENCY_LOCK" ]; then
  printf '%s\n' "Renderer dependency lock is missing or unsafe: $DEPENDENCY_LOCK" >&2
  exit 1
fi
/bin/bash "$ROOT/Scripts/verify-renderer-dependency-lock.sh" "$DEPENDENCY_LOCK" >/dev/null
if [ ! -s "$BUILD_MANIFEST" ] || [ -L "$BUILD_MANIFEST" ]; then
  printf '%s\n' "Renderer build manifest is missing or unsafe: $BUILD_MANIFEST" >&2
  exit 1
fi
if [ ! -s "$MACHO_DIGESTS" ] || [ -L "$MACHO_DIGESTS" ]; then
  printf '%s\n' "Renderer Mach-O digest inventory is missing or unsafe: $MACHO_DIGESTS" >&2
  exit 1
fi

if ! awk -F '\t' '
    BEGIN {
      expected[1] = "manifest-version"
      expected[2] = "renderer-version"
      expected[3] = "upstream-source-ref"
      expected[4] = "source-fingerprint"
      expected[5] = "source-file-count"
      expected[6] = "architectures"
      expected[7] = "deployment-target"
      expected[8] = "dependency-lock-sha256"
      expected[9] = "dependency-lock-line-count"
      expected[10] = "macho-slice-digests-sha256"
      expected[11] = "macho-slice-digests-line-count"
    }
    NF != 2 || $1 != expected[NR] || $2 == "" { exit 1 }
    END { if (NR != 11) exit 1 }
  ' "$BUILD_MANIFEST"; then
  printf '%s\n' "Renderer build manifest is malformed or non-canonical: $BUILD_MANIFEST" >&2
  exit 1
fi

manifest_value() {
  awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$BUILD_MANIFEST"
}

MANIFEST_VERSION="$(manifest_value manifest-version)"
MANIFEST_RENDERER_VERSION="$(manifest_value renderer-version)"
MANIFEST_SOURCE_REF="$(manifest_value upstream-source-ref)"
MANIFEST_SOURCE_FINGERPRINT="$(manifest_value source-fingerprint)"
MANIFEST_SOURCE_FILE_COUNT="$(manifest_value source-file-count)"
MANIFEST_ARCHITECTURES="$(manifest_value architectures)"
MANIFEST_DEPLOYMENT_TARGET="$(manifest_value deployment-target)"
MANIFEST_DEPENDENCY_LOCK_SHA256="$(manifest_value dependency-lock-sha256)"
MANIFEST_DEPENDENCY_LOCK_LINE_COUNT="$(manifest_value dependency-lock-line-count)"
MANIFEST_MACHO_DIGESTS_SHA256="$(manifest_value macho-slice-digests-sha256)"
MANIFEST_MACHO_DIGESTS_LINE_COUNT="$(manifest_value macho-slice-digests-line-count)"

if [ "$MANIFEST_VERSION" != "2" ] \
    || ! printf '%s\n' "$MANIFEST_RENDERER_VERSION" | /usr/bin/grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$' \
    || ! printf '%s\n' "$MANIFEST_SOURCE_REF" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' \
    || ! printf '%s\n' "$MANIFEST_SOURCE_FINGERPRINT" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' \
    || ! printf '%s\n' "$MANIFEST_SOURCE_FILE_COUNT" | /usr/bin/grep -Eq '^[1-9][0-9]*$' \
    || ! printf '%s\n' "$MANIFEST_DEPLOYMENT_TARGET" | /usr/bin/grep -Eq '^[0-9]+([.][0-9]+){0,2}$' \
    || ! printf '%s\n' "$MANIFEST_DEPENDENCY_LOCK_SHA256" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' \
    || ! printf '%s\n' "$MANIFEST_DEPENDENCY_LOCK_LINE_COUNT" | /usr/bin/grep -Eq '^[1-9][0-9]*$' \
    || ! printf '%s\n' "$MANIFEST_MACHO_DIGESTS_SHA256" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' \
    || ! printf '%s\n' "$MANIFEST_MACHO_DIGESTS_LINE_COUNT" | /usr/bin/grep -Eq '^[1-9][0-9]*$'; then
  printf '%s\n' "Renderer build manifest contains an invalid value: $BUILD_MANIFEST" >&2
  exit 1
fi
if [ "$MANIFEST_ARCHITECTURES" != "$EXPECTED_ARCHITECTURES" ]; then
  printf '%s\n' \
    "Renderer build manifest architecture mismatch: expected $EXPECTED_ARCHITECTURES, found $MANIFEST_ARCHITECTURES" >&2
  exit 1
fi

CURRENT_PROVENANCE="$(/usr/bin/perl "$ROOT/Scripts/renderer-source-fingerprint.pl" \
  "$ROOT/ExternalRenderers/wallpaperengine-mac-renderer")"
CURRENT_RENDERER_VERSION="$(printf '%s\n' "$CURRENT_PROVENANCE" | awk -F '\t' '$1 == "renderer-version" { print $2 }')"
CURRENT_SOURCE_REF="$(printf '%s\n' "$CURRENT_PROVENANCE" | awk -F '\t' '$1 == "upstream-source-ref" { print $2 }')"
CURRENT_SOURCE_FINGERPRINT="$(printf '%s\n' "$CURRENT_PROVENANCE" | awk -F '\t' '$1 == "source-fingerprint" { print $2 }')"
CURRENT_SOURCE_FILE_COUNT="$(printf '%s\n' "$CURRENT_PROVENANCE" | awk -F '\t' '$1 == "source-file-count" { print $2 }')"
if [ "$MANIFEST_RENDERER_VERSION" != "$CURRENT_RENDERER_VERSION" ] \
    || [ "$MANIFEST_SOURCE_REF" != "$CURRENT_SOURCE_REF" ] \
    || [ "$MANIFEST_SOURCE_FINGERPRINT" != "$CURRENT_SOURCE_FINGERPRINT" ] \
    || [ "$MANIFEST_SOURCE_FILE_COUNT" != "$CURRENT_SOURCE_FILE_COUNT" ]; then
  printf '%s\n' \
    "Renderer build manifest does not match the current canonical renderer source: $BUILD_MANIFEST" >&2
  exit 1
fi
EXPECTED_BINARY_BINDING="background-engine-renderer-provenance-v1|${MANIFEST_RENDERER_VERSION}|${MANIFEST_SOURCE_REF}|${MANIFEST_SOURCE_FINGERPRINT}|${MANIFEST_SOURCE_FILE_COUNT}"

ACTUAL_DEPENDENCY_LOCK_SHA256="$(shasum -a 256 "$DEPENDENCY_LOCK" | awk '{ print $1 }')"
ACTUAL_DEPENDENCY_LOCK_LINE_COUNT="$(awk 'END { print NR + 0 }' "$DEPENDENCY_LOCK")"
if [ "$MANIFEST_DEPENDENCY_LOCK_SHA256" != "$ACTUAL_DEPENDENCY_LOCK_SHA256" ] \
    || [ "$MANIFEST_DEPENDENCY_LOCK_LINE_COUNT" != "$ACTUAL_DEPENDENCY_LOCK_LINE_COUNT" ]; then
  printf '%s\n' "Renderer dependency lock does not match its build manifest: $DEPENDENCY_LOCK" >&2
  exit 1
fi

ACTUAL_MACHO_DIGESTS_SHA256="$(shasum -a 256 "$MACHO_DIGESTS" | awk '{ print $1 }')"
ACTUAL_MACHO_DIGESTS_LINE_COUNT="$(awk 'END { print NR + 0 }' "$MACHO_DIGESTS")"
if [ "$MANIFEST_MACHO_DIGESTS_SHA256" != "$ACTUAL_MACHO_DIGESTS_SHA256" ] \
    || [ "$MANIFEST_MACHO_DIGESTS_LINE_COUNT" != "$ACTUAL_MACHO_DIGESTS_LINE_COUNT" ]; then
  printf '%s\n' \
    "Renderer Mach-O digest inventory does not match its build manifest: $MACHO_DIGESTS" >&2
  exit 1
fi
if ! awk -F '\t' '
    NF != 3 { exit 1 }
    $1 != "background-engine-scene-renderer" \
      && $1 !~ /^lib\/[0-9A-Za-z][0-9A-Za-z._+-]*[.]dylib$/ { exit 1 }
    $2 != "arm64" && $2 != "x86_64" { exit 1 }
    $3 !~ /^[0-9a-f]{64}$/ { exit 1 }
  ' "$MACHO_DIGESTS" \
    || ! LC_ALL=C sort -c -t $'\t' -k1,1 -k2,2 "$MACHO_DIGESTS"; then
  printf '%s\n' "Renderer Mach-O digest inventory is malformed or non-canonical: $MACHO_DIGESTS" >&2
  exit 1
fi

while IFS= read -r entry; do
  case "$entry" in
    "$RENDERER")
      [ -f "$entry" ] && [ ! -L "$entry" ] || {
        printf '%s\n' "Renderer executable must be a regular file: $entry" >&2
        exit 1
      }
      ;;
    "$LIBRARY_ROOT")
      ;;
    "$DEPENDENCY_LOCK")
      [ -s "$entry" ] && [ ! -L "$entry" ] || {
        printf '%s\n' "Renderer dependency lock must be a non-empty regular file: $entry" >&2
        exit 1
      }
      ;;
    "$BUILD_MANIFEST")
      [ -s "$entry" ] && [ ! -L "$entry" ] || {
        printf '%s\n' "Renderer build manifest must be a non-empty regular file: $entry" >&2
        exit 1
      }
      ;;
    "$MACHO_DIGESTS")
      [ -s "$entry" ] && [ ! -L "$entry" ] || {
        printf '%s\n' "Renderer Mach-O digest inventory must be a non-empty regular file: $entry" >&2
        exit 1
      }
      ;;
    "$LIBRARY_ROOT"/*)
      if [ "$(dirname "$entry")" != "$LIBRARY_ROOT" ] \
          || { [ ! -f "$entry" ] && [ ! -L "$entry" ]; }; then
        printf '%s\n' "Renderer runtime contains an unsupported library entry: $entry" >&2
        exit 1
      fi
      ;;
    *)
      printf '%s\n' "Renderer runtime contains an unexpected entry: $entry" >&2
      exit 1
      ;;
  esac
done < <(find "$RUNTIME" -mindepth 1 -print | LC_ALL=C sort)

MACHO_FILES=("$RENDERER")
while IFS= read -r library; do
  if ! /usr/bin/file "$library" | /usr/bin/grep -Eq 'Mach-O'; then
    printf '%s\n' "Renderer runtime library is not Mach-O: $library" >&2
    exit 1
  fi
  MACHO_FILES+=("$library")
done < <(find "$LIBRARY_ROOT" -type f -print | LC_ALL=C sort)

if ! /usr/bin/file "$RENDERER" | /usr/bin/grep -Eq 'Mach-O'; then
  printf '%s\n' "Renderer executable is not Mach-O: $RENDERER" >&2
  exit 1
fi

MACHO_COUNT=0
for file_path in "${MACHO_FILES[@]}"; do
  MACHO_COUNT=$((MACHO_COUNT + 1))

  file_has_arm64=0
  file_has_x86_64=0
  for file_architecture in $(lipo -archs "$file_path"); do
    case "$file_architecture" in
      arm64) file_has_arm64=1 ;;
      x86_64) file_has_x86_64=1 ;;
      *)
        printf '%s\n' \
          "Renderer Mach-O contains an unsupported architecture: $file_path [$file_architecture]" >&2
        exit 1
        ;;
    esac
  done
  if [ "$file_has_arm64" -eq 1 ] && [ "$file_has_x86_64" -eq 1 ]; then
    file_architectures_value="arm64,x86_64"
  elif [ "$file_has_arm64" -eq 1 ]; then
    file_architectures_value="arm64"
  elif [ "$file_has_x86_64" -eq 1 ]; then
    file_architectures_value="x86_64"
  else
    printf '%s\n' "Renderer Mach-O contains no supported architecture: $file_path" >&2
    exit 1
  fi
  if [ "$file_architectures_value" != "$EXPECTED_ARCHITECTURES" ]; then
    printf '%s\n' \
      "Renderer Mach-O architecture set is not exact: $file_path [$file_architectures_value]" >&2
    exit 1
  fi

  for architecture in "${VERIFY_ARCHITECTURES[@]}"; do
    lipo "$file_path" -verify_arch "$architecture"

    if [ "$file_path" = "$RENDERER" ]; then
      binary_bindings="$(/usr/bin/strings -arch "$architecture" -- "$RENDERER" \
        | /usr/bin/grep -E '^background-engine-renderer-provenance-v1[|]' || true)"
      if [ "$(printf '%s\n' "$binary_bindings" | awk 'NF { count += 1 } END { print count + 0 }')" -ne 1 ] \
          || [ "$binary_bindings" != "$EXPECTED_BINARY_BINDING" ]; then
        printf '%s\n' \
          "Renderer binary provenance does not match its build manifest: $RENDERER [$architecture]" >&2
        exit 1
      fi
    fi

    case "$file_path" in
      "$RUNTIME/lib/"*)
        relative="${file_path#"$RUNTIME"/lib/}"
        identifier="$(otool -arch "$architecture" -D "$file_path" \
          | awk 'NR > 1 && NF { print; exit }')"
        expected_identifier="@executable_path/lib/$relative"
        if [ "$identifier" != "$expected_identifier" ]; then
          printf '%s\n' "Renderer dylib install ID is not canonical: $file_path [$architecture] -> $identifier" >&2
          exit 1
        fi
        ;;
    esac

    while IFS= read -r dependency; do
      [ -n "$dependency" ] || continue
      case "$dependency" in
        /System/Library/*|/usr/lib/*)
          ;;
        @executable_path/lib/*)
          relative="${dependency#@executable_path/lib/}"
          case "$relative" in
            ""|/*|.|..|*/./*|*/../*|*/.|*/..)
              printf '%s\n' "Renderer dependency escapes its runtime: $file_path [$architecture] -> $dependency" >&2
              exit 1
              ;;
          esac
          if [ ! -e "$RUNTIME/lib/$relative" ] && [ ! -L "$RUNTIME/lib/$relative" ]; then
            printf '%s\n' "Renderer dependency is missing: $file_path [$architecture] -> $dependency" >&2
            exit 1
          fi
          ;;
        /opt/homebrew/*|/usr/local/*)
          printf '%s\n' "Renderer contains a Homebrew-only dependency: $file_path [$architecture] -> $dependency" >&2
          exit 1
          ;;
        @rpath/*|@loader_path/*)
          printf '%s\n' "Renderer contains an unresolved dependency: $file_path [$architecture] -> $dependency" >&2
          exit 1
          ;;
        *)
          printf '%s\n' "Renderer contains a non-system external dependency: $file_path [$architecture] -> $dependency" >&2
          exit 1
          ;;
      esac
    done < <(otool -arch "$architecture" -L "$file_path" | awk '$2 == "(compatibility" { print $1 }')

    rpaths="$(otool -arch "$architecture" -l "$file_path" | awk '
      $1 == "cmd" && $2 == "LC_RPATH" { want_path = 1; next }
      want_path && $1 == "path" { print $2; want_path = 0 }
    ')"
    rpath_count="$(printf '%s\n' "$rpaths" | awk 'NF { count += 1 } END { print count + 0 }')"
    if [ "$rpath_count" -ne 1 ] || [ "$rpaths" != "@executable_path/lib/" ]; then
      printf '%s\n' "Renderer Mach-O must contain exactly one @executable_path/lib/ LC_RPATH: $file_path [$architecture]" >&2
      exit 1
    fi

    deployment_records="$(otool -arch "$architecture" -l "$file_path" | awk '
      function flushDeployment() {
        if (command == "LC_BUILD_VERSION" && minimum != "") {
          # Older otool prints the Mach-O platform enum (1) while newer
          # toolchains may print its symbolic MACOS name.
          print (platform == "1" ? "MACOS" : platform) "\t" minimum
        } else if (command == "LC_VERSION_MIN_MACOSX" && minimum != "") {
          print "MACOS\t" minimum
        }
      }
      $1 == "cmd" {
        flushDeployment()
        command = $2
        platform = ""
        minimum = ""
        next
      }
      command == "LC_BUILD_VERSION" && $1 == "platform" { platform = $2; next }
      command == "LC_BUILD_VERSION" && $1 == "minos" { minimum = $2; next }
      command == "LC_VERSION_MIN_MACOSX" && $1 == "version" { minimum = $2; next }
      END { flushDeployment() }
    ')"
    minimum_count="$(printf '%s\n' "$deployment_records" | awk 'NF { count += 1 } END { print count + 0 }')"
    deployment_platform="$(printf '%s\n' "$deployment_records" | awk 'NF { print $1; exit }')"
    minimum_macos="$(printf '%s\n' "$deployment_records" | awk 'NF { print $2; exit }')"
    if [ "$minimum_count" -ne 1 ] \
        || [ "$deployment_platform" != "MACOS" ] \
        || ! printf '%s\n' "$minimum_macos" \
          | /usr/bin/grep -Eq '^[0-9]+([.][0-9]+){0,2}$'; then
      printf '%s\n' \
        "Renderer Mach-O has an invalid macOS platform or deployment target: $file_path [$architecture]" >&2
      exit 1
    fi
    if ! awk -v actual="$minimum_macos" -v maximum="14.0" 'BEGIN {
        actualCount = split(actual, actualParts, ".")
        maximumCount = split(maximum, maximumParts, ".")
        count = actualCount > maximumCount ? actualCount : maximumCount
        for (componentIndex = 1; componentIndex <= count; componentIndex += 1) {
          actualPart = componentIndex <= actualCount ? actualParts[componentIndex] + 0 : 0
          maximumPart = componentIndex <= maximumCount ? maximumParts[componentIndex] + 0 : 0
          if (actualPart < maximumPart) exit 0
          if (actualPart > maximumPart) exit 1
        }
        exit 0
      }'; then
      printf '%s\n' \
        "Renderer Mach-O requires macOS $minimum_macos, above the supported 14.0 target: $file_path [$architecture]" >&2
      exit 1
    fi
    if [ "$file_path" = "$RENDERER" ] && [ "$minimum_macos" != "$MANIFEST_DEPLOYMENT_TARGET" ]; then
      printf '%s\n' \
        "Renderer executable deployment target does not match its build manifest: $file_path [$architecture]" >&2
      exit 1
    fi
  done

  codesign --verify --strict "$file_path"
done

ACTUAL_DIGESTS="$(mktemp)"
DIGEST_STAGING="$(mktemp -d)"
cleanup_digests() {
  cleanup_status="$?"
  rm -f "$ACTUAL_DIGESTS"
  rm -rf "$DIGEST_STAGING"
  return "$cleanup_status"
}
trap cleanup_digests EXIT
for file_path in "${MACHO_FILES[@]}"; do
  relative_path="${file_path#"$RUNTIME"/}"
  for architecture in "${VERIFY_ARCHITECTURES[@]}"; do
    if [ "$EXPECTED_ARCHITECTURES" = "$architecture" ]; then
      slice_sha256="$(shasum -a 256 "$file_path" | awk '{ print $1 }')"
    else
      thin_slice="$DIGEST_STAGING/.slice-${architecture}-$(basename "$file_path")"
      if [ -e "$thin_slice" ] || [ -L "$thin_slice" ]; then
        printf '%s\n' \
          "Renderer Mach-O basenames collide while verifying digest inventory: $file_path" >&2
        exit 1
      fi
      lipo "$file_path" -thin "$architecture" -output "$thin_slice"
      slice_sha256="$(shasum -a 256 "$thin_slice" | awk '{ print $1 }')"
      rm -f "$thin_slice"
    fi
    printf '%s\t%s\t%s\n' "$relative_path" "$architecture" "$slice_sha256" \
      >> "$ACTUAL_DIGESTS"
  done
done
if ! cmp -s "$ACTUAL_DIGESTS" "$MACHO_DIGESTS"; then
  printf '%s\n' \
    "Renderer Mach-O slice digest inventory does not match the packaged bytes: $MACHO_DIGESTS" >&2
  exit 1
fi
rm -f "$ACTUAL_DIGESTS"
rm -rf "$DIGEST_STAGING"
trap - EXIT

while IFS= read -r link_path; do
  if [ "$(dirname "$link_path")" != "$RUNTIME/lib" ]; then
    printf '%s\n' "Renderer runtime symlink is outside its library root: $link_path" >&2
    exit 1
  fi
  target="$(readlink "$link_path")"
  case "$target" in
    ""|/*|.|..|*/*)
      printf '%s\n' "Renderer runtime symlink has an unsafe target: $link_path -> $target" >&2
      exit 1
      ;;
  esac
  if [ ! -f "$RUNTIME/lib/$target" ] || [ -L "$RUNTIME/lib/$target" ]; then
    printf '%s\n' "Renderer runtime symlink target is not a regular bundled library: $link_path -> $target" >&2
    exit 1
  fi
done < <(find "$RUNTIME" -type l -print)

if [ "$MACHO_COUNT" -eq 0 ]; then
  printf '%s\n' "Renderer runtime contains no Mach-O files: $RUNTIME" >&2
  exit 1
fi

if [ -f "$RUNTIME/lib/libSDL2-2.0.0.dylib" ] && [ ! -e "$RUNTIME/lib/libSDL3.dylib" ]; then
  printf '%s\n' "Renderer sdl2-compat runtime is missing libSDL3.dylib." >&2
  exit 1
fi

printf '%s\n' "Verified renderer runtime: $RUNTIME"
