#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
# shellcheck source=runtime-script-common.sh
source "$script_directory/runtime-script-common.sh"
be_require_tools perl mktemp mkdir touch dirname basename shasum awk find wc printf rm pwd

renderer=${1:-}
if [[ -z "$renderer" || ! -x "$renderer" ]]; then
  echo "Usage: $0 /path/to/background-engine-scene-renderer" >&2
  exit 64
fi
renderer_directory="$(cd "$(/usr/bin/dirname "$renderer")" && /bin/pwd -P)"
renderer="$renderer_directory/$(/usr/bin/basename "$renderer")"

temporary_parent=${TMPDIR:-/tmp}
temporary_parent=${temporary_parent%/}
if [[ -z "$temporary_parent" || "$temporary_parent" == "/" || "$temporary_parent" != /* || ! -d "$temporary_parent" ]]; then
  echo "Refusing unsafe temporary parent: ${TMPDIR:-/tmp}" >&2
  exit 64
fi
temporary_parent="$(cd "$temporary_parent" && /bin/pwd -P)"
if [[ -z "$temporary_parent" || "$temporary_parent" == "/" ]]; then
  echo "Refusing unsafe canonical temporary parent: $temporary_parent" >&2
  exit 64
fi
fixture_root=$(/usr/bin/mktemp -d "$temporary_parent/background-engine-standalone-scene.XXXXXX")
cleanup() {
  if [[ -n "${fixture_root:-}" && "$fixture_root" == "$temporary_parent"/background-engine-standalone-scene.* ]]; then
    /bin/rm -R "$fixture_root"
  fi
}
trap cleanup EXIT

project="$fixture_root/project"
assets="$fixture_root/assets"
package="$project/scene.pkg"
/bin/mkdir -p "$project" "$assets"

required_assets=(
  models/util/composelayer.json
  materials/util/composelayer.json
  materials/util/effectpassthrough.json
  materials/util/downsample_quarter_bloom.json
  materials/util/downsample_eighth_blur_v.json
  materials/util/blur_h_bloom.json
  materials/util/combine.json
  shaders/genericimage2.frag
  shaders/genericimage2.vert
  shaders/common_blur.h
  shaders/genericparticle.vert
  shaders/genericparticle.frag
)
for relative_path in "${required_assets[@]}"; do
  /bin/mkdir -p "$assets/$(/usr/bin/dirname "$relative_path")"
  /usr/bin/touch "$assets/$relative_path"
done

/usr/bin/perl - "$package" <<'PERL'
use strict;
use warnings;
use bytes;

my ($path) = @ARGV;
my $scene = '{"camera":{"center":"0 0 0","eye":"0 0 1","up":"0 1 0"},"general":{"orthogonalprojection":{"width":320,"height":180}},"objects":[]}';
open my $output, '>:raw', $path or die "Cannot create $path: $!";
sub write_string {
    my ($handle, $value) = @_;
    print {$handle} pack('l<', length($value)), $value;
}
write_string($output, 'PKGV0007');
print {$output} pack('l<', 1);
write_string($output, 'scene.json');
print {$output} pack('l<', 0), pack('l<', length($scene)), $scene;
close $output or die "Cannot close $path: $!";
PERL

run_renderer_load() {
  /usr/bin/perl -e 'alarm 30; exec @ARGV' \
    "$renderer" \
    --silent \
    --noautomute \
    --no-audio-processing \
    --disable-mouse \
    --list-properties \
    --assets-dir "$assets" \
    --scene-package "$package" \
    "$project"
}

# A standalone PKGV import must load without requiring or creating metadata.
run_renderer_load
test ! -e "$project/project.json"

# Existing metadata stays byte-for-byte intact. The explicit package remains
# authoritative even when stale unpacked scene.json bytes sit beside it.
/usr/bin/printf '%s' \
  '{"title":"Authored title","type":"scene","file":"scene.pkg","workshopid":"123","general":{"supportsaudioprocessing":true}}' \
  > "$project/project.json"
/usr/bin/printf '%s' '{malformed-stale-scene' > "$project/scene.json"
metadata_hash_before=$(/usr/bin/shasum -a 256 "$project/project.json" | /usr/bin/awk '{print $1}')
run_renderer_load
metadata_hash_after=$(/usr/bin/shasum -a 256 "$project/project.json" | /usr/bin/awk '{print $1}')
test "$metadata_hash_before" = "$metadata_hash_after"

# Exercise the real offscreen render path as well as metadata parsing. A
# synthetic empty Scene intentionally needs no proprietary engine resources;
# the renderer still validates the expected asset-tree shape above.
frames="$fixture_root/frames"
/bin/mkdir "$frames"
/usr/bin/perl -e 'alarm 30; exec @ARGV' \
  "$renderer" \
  --window 0x0x320x180 \
  --silent \
  --noautomute \
  --no-audio-processing \
  --disable-mouse \
  --record-dir "$frames" \
  --record-seconds 1 \
  --record-fps 2 \
  --assets-dir "$assets" \
  --scene-package "$package" \
  "$project"
frame_count=$(/usr/bin/find "$frames" -type f -name 'frame_*.png' -size +0c | /usr/bin/wc -l | /usr/bin/awk '{print $1}')
test "$frame_count" = "2"

# The fallback path keeps its original fail-closed contract: without an
# explicit package, a project still needs project.json.
/bin/rm "$project/project.json" "$project/scene.json"
if /usr/bin/perl -e 'alarm 30; exec @ARGV' \
  "$renderer" \
  --silent \
  --noautomute \
  --no-audio-processing \
  --disable-mouse \
  --list-properties \
  --assets-dir "$assets" \
  "$project" > "$fixture_root/ordinary.stdout" 2> "$fixture_root/ordinary.stderr"; then
  echo "Renderer accepted a project without project.json when --scene-package was absent." >&2
  exit 1
fi

echo "Standalone Scene package smoke test passed."
