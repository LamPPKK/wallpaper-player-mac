#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  printf '%s\n' \
    "usage: $0 /path/to/renderer-runtime arm64|x86_64|arm64,x86_64 [--refresh-after-signing]" >&2
  exit 64
fi

RUNTIME="$(cd "$1" && pwd -P)"
ARCHITECTURES_VALUE="$2"
case "$ARCHITECTURES_VALUE" in
  arm64)
    ARCHITECTURES=(arm64)
    ;;
  x86_64)
    ARCHITECTURES=(x86_64)
    ;;
  arm64,x86_64)
    ARCHITECTURES=(arm64 x86_64)
    ;;
  *)
    printf '%s\n' \
      "Unsupported renderer build manifest architecture set: $ARCHITECTURES_VALUE" >&2
    exit 64
    ;;
esac
REFRESH_AFTER_SIGNING=0
if [ "$#" -eq 3 ]; then
  if [ "$3" != "--refresh-after-signing" ]; then
    printf '%s\n' "Unsupported renderer build manifest option: $3" >&2
    exit 64
  fi
  REFRESH_AFTER_SIGNING=1
fi

be_require_tools file find lipo otool awk sort cmp shasum mktemp mv dirname \
  basename rm mkdir /usr/bin/perl /usr/bin/grep /usr/bin/strings

RENDERER="$RUNTIME/background-engine-scene-renderer"
LIBRARY_ROOT="$RUNTIME/lib"
DEPENDENCY_LOCK="$RUNTIME/dependencies.lock.tsv"
MANIFEST="$RUNTIME/renderer-build-manifest.tsv"
MACHO_DIGESTS="$RUNTIME/macho-slice-digests.tsv"
if [ ! -f "$RENDERER" ] || [ -L "$RENDERER" ] || [ ! -x "$RENDERER" ]; then
  printf '%s\n' "Renderer executable is missing or unsafe: $RENDERER" >&2
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
if [ "$REFRESH_AFTER_SIGNING" -eq 0 ]; then
  if [ -e "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
    printf '%s\n' "Refusing to overwrite renderer build manifest: $MANIFEST" >&2
    exit 1
  fi
  if [ -e "$MACHO_DIGESTS" ] || [ -L "$MACHO_DIGESTS" ]; then
    printf '%s\n' "Refusing to overwrite renderer Mach-O digest inventory: $MACHO_DIGESTS" >&2
    exit 1
  fi
else
  if [ ! -s "$MANIFEST" ] || [ -L "$MANIFEST" ] \
      || [ ! -s "$MACHO_DIGESTS" ] || [ -L "$MACHO_DIGESTS" ]; then
    printf '%s\n' \
      "Renderer metadata refresh requires an existing safe manifest and digest inventory: $RUNTIME" >&2
    exit 1
  fi
fi

deployment_target=""
for architecture in "${ARCHITECTURES[@]}"; do
  lipo "$RENDERER" -verify_arch "$architecture"
  deployment_records="$(otool -arch "$architecture" -l "$RENDERER" | awk '
  function flushDeployment() {
    if (command == "LC_BUILD_VERSION" && minimum != "") {
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
  if [ "$(printf '%s\n' "$deployment_records" | awk 'NF { count += 1 } END { print count + 0 }')" -ne 1 ]; then
    printf '%s\n' \
      "Renderer executable has invalid deployment metadata: $RENDERER [$architecture]" >&2
    exit 1
  fi
  deployment_platform="$(printf '%s\n' "$deployment_records" | awk 'NF { print $1; exit }')"
  architecture_deployment_target="$(printf '%s\n' "$deployment_records" | awk 'NF { print $2; exit }')"
  if [ "$deployment_platform" != "MACOS" ] \
      || ! printf '%s\n' "$architecture_deployment_target" \
        | /usr/bin/grep -Eq '^[0-9]+([.][0-9]+){0,2}$'; then
    printf '%s\n' \
      "Renderer executable is not a valid macOS binary: $RENDERER [$architecture]" >&2
    exit 1
  fi
  if [ -z "$deployment_target" ]; then
    deployment_target="$architecture_deployment_target"
  elif [ "$deployment_target" != "$architecture_deployment_target" ]; then
    printf '%s\n' \
      "Renderer executable deployment targets differ between architectures: $RENDERER" >&2
    exit 1
  fi
done

provenance="$(/usr/bin/perl "$ROOT/Scripts/renderer-source-fingerprint.pl" \
  "$ROOT/ExternalRenderers/wallpaperengine-mac-renderer")"
renderer_version="$(printf '%s\n' "$provenance" | awk -F '\t' '$1 == "renderer-version" { print $2 }')"
upstream_source_ref="$(printf '%s\n' "$provenance" | awk -F '\t' '$1 == "upstream-source-ref" { print $2 }')"
source_fingerprint="$(printf '%s\n' "$provenance" | awk -F '\t' '$1 == "source-fingerprint" { print $2 }')"
source_file_count="$(printf '%s\n' "$provenance" | awk -F '\t' '$1 == "source-file-count" { print $2 }')"
expected_binding="background-engine-renderer-provenance-v1|${renderer_version}|${upstream_source_ref}|${source_fingerprint}|${source_file_count}"
for architecture in "${ARCHITECTURES[@]}"; do
  binary_bindings="$(/usr/bin/strings -arch "$architecture" -- "$RENDERER" \
    | /usr/bin/grep -E '^background-engine-renderer-provenance-v1[|]' || true)"
  if [ "$(printf '%s\n' "$binary_bindings" | awk 'NF { count += 1 } END { print count + 0 }')" -ne 1 ] \
      || [ "$binary_bindings" != "$expected_binding" ]; then
    printf '%s\n' \
      "Renderer binary provenance does not match the current canonical source: $RENDERER [$architecture]" >&2
    exit 1
  fi
done
dependency_lock_sha256="$(shasum -a 256 "$DEPENDENCY_LOCK" | awk '{ print $1 }')"
dependency_lock_line_count="$(awk 'END { print NR + 0 }' "$DEPENDENCY_LOCK")"

if [ "$REFRESH_AFTER_SIGNING" -eq 1 ]; then
  if ! awk -F '\t' -v architectures="$ARCHITECTURES_VALUE" \
      -v renderer_version="$renderer_version" -v source_ref="$upstream_source_ref" \
      -v source_fingerprint="$source_fingerprint" -v source_count="$source_file_count" \
      -v dependency_sha="$dependency_lock_sha256" -v dependency_count="$dependency_lock_line_count" '
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
      $1 == "manifest-version" && $2 != "2" { exit 1 }
      $1 == "renderer-version" && $2 != renderer_version { exit 1 }
      $1 == "upstream-source-ref" && $2 != source_ref { exit 1 }
      $1 == "source-fingerprint" && $2 != source_fingerprint { exit 1 }
      $1 == "source-file-count" && $2 != source_count { exit 1 }
      $1 == "architectures" && $2 != architectures { exit 1 }
      $1 == "dependency-lock-sha256" && $2 != dependency_sha { exit 1 }
      $1 == "dependency-lock-line-count" && $2 != dependency_count { exit 1 }
      END { if (NR != 11) exit 1 }
    ' "$MANIFEST"; then
    printf '%s\n' \
      "Refusing to refresh stale or malformed renderer build metadata: $MANIFEST" >&2
    exit 1
  fi
  old_inventory_sha="$(shasum -a 256 "$MACHO_DIGESTS" | awk '{ print $1 }')"
  old_inventory_count="$(awk 'END { print NR + 0 }' "$MACHO_DIGESTS")"
  manifest_inventory_sha="$(awk -F '\t' '$1 == "macho-slice-digests-sha256" { print $2 }' "$MANIFEST")"
  manifest_inventory_count="$(awk -F '\t' '$1 == "macho-slice-digests-line-count" { print $2 }' "$MANIFEST")"
  if [ "$old_inventory_sha" != "$manifest_inventory_sha" ] \
      || [ "$old_inventory_count" != "$manifest_inventory_count" ]; then
    printf '%s\n' \
      "Refusing to refresh renderer metadata whose prior digest inventory is not manifest-bound: $RUNTIME" >&2
    exit 1
  fi
fi

STAGING="$(mktemp -d "$RUNTIME/.renderer-build-metadata.XXXXXX")"
STAGED_DIGESTS="$STAGING/macho-slice-digests.tsv"
STAGED_MANIFEST="$STAGING/renderer-build-manifest.tsv"
BACKUP_MANIFEST="$STAGING/renderer-build-manifest.previous.tsv"
BACKUP_DIGESTS="$STAGING/macho-slice-digests.previous.tsv"
BACKED_UP_MANIFEST=0
BACKED_UP_DIGESTS=0
PUBLISHED_MANIFEST=0
PUBLISHED_DIGESTS=0
cleanup() {
  cleanup_status="$?"
  restore_failed=0
  set +e
  if [ "$PUBLISHED_MANIFEST" -eq 1 ]; then
    if ! rm -f "$MANIFEST"; then
      printf '%s\n' "Unable to remove incomplete renderer build manifest: $MANIFEST" >&2
      restore_failed=1
    fi
  fi
  if [ "$PUBLISHED_DIGESTS" -eq 1 ]; then
    if ! rm -f "$MACHO_DIGESTS"; then
      printf '%s\n' "Unable to remove incomplete renderer digest inventory: $MACHO_DIGESTS" >&2
      restore_failed=1
    fi
  fi
  if [ "$BACKED_UP_DIGESTS" -eq 1 ]; then
    if [ ! -f "$BACKUP_DIGESTS" ] || [ -L "$BACKUP_DIGESTS" ] \
        || [ -e "$MACHO_DIGESTS" ] || [ -L "$MACHO_DIGESTS" ]; then
      printf '%s\n' "Cannot safely restore renderer digest inventory; retaining its backup." >&2
      restore_failed=1
    elif ! mv "$BACKUP_DIGESTS" "$MACHO_DIGESTS"; then
      printf '%s\n' "Unable to restore renderer digest inventory: $MACHO_DIGESTS" >&2
      restore_failed=1
    fi
  fi
  if [ "$BACKED_UP_MANIFEST" -eq 1 ]; then
    if [ ! -f "$BACKUP_MANIFEST" ] || [ -L "$BACKUP_MANIFEST" ] \
        || [ -e "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
      printf '%s\n' "Cannot safely restore renderer build manifest; retaining its backup." >&2
      restore_failed=1
    elif ! mv "$BACKUP_MANIFEST" "$MANIFEST"; then
      printf '%s\n' "Unable to restore renderer build manifest: $MANIFEST" >&2
      restore_failed=1
    fi
  fi
  if [ "$restore_failed" -eq 0 ]; then
    [ ! -d "$STAGING" ] || rm -rf "$STAGING"
  else
    printf '%s\n' "Renderer metadata rollback was incomplete; recover retained files from: $STAGING" >&2
  fi
  return "$cleanup_status"
}
trap cleanup EXIT

MACHO_PATHS=("$RENDERER")
while IFS= read -r library; do
  if [ "$(dirname "$library")" != "$LIBRARY_ROOT" ]; then
    printf '%s\n' "Renderer runtime contains a nested library: $library" >&2
    exit 1
  fi
  library_name="$(basename "$library")"
  if ! printf '%s\n' "$library_name" \
      | /usr/bin/grep -Eq '^[0-9A-Za-z][0-9A-Za-z._+-]*[.]dylib$'; then
    printf '%s\n' "Renderer runtime contains an unsafe dylib name: $library_name" >&2
    exit 1
  fi
  if ! /usr/bin/file "$library" | /usr/bin/grep -Eq 'Mach-O'; then
    printf '%s\n' "Renderer runtime library is not Mach-O: $library" >&2
    exit 1
  fi
  MACHO_PATHS+=("$library")
done < <(find "$LIBRARY_ROOT" -type f -print | LC_ALL=C sort)
if ! /usr/bin/file "$RENDERER" | /usr/bin/grep -Eq 'Mach-O'; then
  printf '%s\n' "Renderer executable is not Mach-O: $RENDERER" >&2
  exit 1
fi

for macho_path in "${MACHO_PATHS[@]}"; do
  relative_path="${macho_path#"$RUNTIME"/}"
  file_has_arm64=0
  file_has_x86_64=0
  for file_architecture in $(lipo -archs "$macho_path"); do
    case "$file_architecture" in
      arm64) file_has_arm64=1 ;;
      x86_64) file_has_x86_64=1 ;;
      *)
        printf '%s\n' \
          "Renderer Mach-O contains an unsupported architecture: $macho_path [$file_architecture]" >&2
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
    printf '%s\n' "Renderer Mach-O contains no supported architecture: $macho_path" >&2
    exit 1
  fi
  if [ "$file_architectures_value" != "$ARCHITECTURES_VALUE" ]; then
    printf '%s\n' \
      "Renderer Mach-O architecture set is not exact: $macho_path [$file_architectures_value]" >&2
    exit 1
  fi
  for architecture in "${ARCHITECTURES[@]}"; do
    lipo "$macho_path" -verify_arch "$architecture"
    if [ "$ARCHITECTURES_VALUE" = "$architecture" ]; then
      slice_sha256="$(shasum -a 256 "$macho_path" | awk '{ print $1 }')"
    else
      thin_slice="$STAGING/.slice-${architecture}-$(basename "$macho_path")"
      if [ -e "$thin_slice" ] || [ -L "$thin_slice" ]; then
        printf '%s\n' "Renderer Mach-O basenames collide while creating digest inventory: $macho_path" >&2
        exit 1
      fi
      lipo "$macho_path" -thin "$architecture" -output "$thin_slice"
      slice_sha256="$(shasum -a 256 "$thin_slice" | awk '{ print $1 }')"
      rm -f "$thin_slice"
    fi
    printf '%s\t%s\t%s\n' "$relative_path" "$architecture" "$slice_sha256" \
      >> "$STAGED_DIGESTS"
  done
done

if ! LC_ALL=C sort -c -t $'\t' -k1,1 -k2,2 "$STAGED_DIGESTS"; then
  printf '%s\n' "Generated renderer Mach-O digest inventory is not canonical." >&2
  exit 1
fi
macho_digest_sha256="$(shasum -a 256 "$STAGED_DIGESTS" | awk '{ print $1 }')"
macho_digest_line_count="$(awk 'END { print NR + 0 }' "$STAGED_DIGESTS")"
{
  printf 'manifest-version\t2\n'
  printf 'renderer-version\t%s\n' "$renderer_version"
  printf 'upstream-source-ref\t%s\n' "$upstream_source_ref"
  printf 'source-fingerprint\t%s\n' "$source_fingerprint"
  printf 'source-file-count\t%s\n' "$source_file_count"
  printf 'architectures\t%s\n' "$ARCHITECTURES_VALUE"
  printf 'deployment-target\t%s\n' "$deployment_target"
  printf 'dependency-lock-sha256\t%s\n' "$dependency_lock_sha256"
  printf 'dependency-lock-line-count\t%s\n' "$dependency_lock_line_count"
  printf 'macho-slice-digests-sha256\t%s\n' "$macho_digest_sha256"
  printf 'macho-slice-digests-line-count\t%s\n' "$macho_digest_line_count"
} > "$STAGED_MANIFEST"

if [ "$REFRESH_AFTER_SIGNING" -eq 1 ]; then
  mv "$MACHO_DIGESTS" "$BACKUP_DIGESTS"
  BACKED_UP_DIGESTS=1
  mv "$MANIFEST" "$BACKUP_MANIFEST"
  BACKED_UP_MANIFEST=1
fi
mv "$STAGED_DIGESTS" "$MACHO_DIGESTS"
PUBLISHED_DIGESTS=1
mv "$STAGED_MANIFEST" "$MANIFEST"
PUBLISHED_MANIFEST=1
BACKED_UP_DIGESTS=0
BACKED_UP_MANIFEST=0
PUBLISHED_DIGESTS=0
PUBLISHED_MANIFEST=0
rm -rf "$STAGING"
trap - EXIT
printf '%s\n' "$MANIFEST"
