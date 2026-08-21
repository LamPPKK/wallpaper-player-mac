#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$repo_root/Scripts/runtime-script-common.sh"

usage() {
  cat <<'USAGE'
usage:
  Scripts/scene-golden-parity.sh --scene <scene.pkg> --golden <dir> --out <dir> \
    --renderer <binary> --assets <dir> --size WxH [--timeout SECONDS] \
    [--static-crop X,Y,W,H] [--mask-rect X,Y,W,H]

Render one deterministic second of a Scene to the same number of PNG frames as
the golden directory, compare every frame, and write summary.json plus a contact
sheet. The output path must not exist.
USAGE
}

die() {
  printf '%s\n' "scene-golden-parity: $*" >&2
  exit 2
}

need_value() {
  [[ $# -gt 1 ]] || die "missing value for $1"
}

scene=""
golden_dir=""
out_dir=""
renderer=""
assets_dir=""
size=""
timeout_seconds=120
static_crop=""
mask_rect=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --scene|--golden|--out|--renderer|--assets|--size|--timeout|--static-crop|--mask-rect)
      need_value "$@"
      case "$1" in
        --scene) scene="$2" ;;
        --golden) golden_dir="$2" ;;
        --out) out_dir="$2" ;;
        --renderer) renderer="$2" ;;
        --assets) assets_dir="$2" ;;
        --size) size="$2" ;;
        --timeout) timeout_seconds="$2" ;;
        --static-crop) static_crop="$2" ;;
        --mask-rect) mask_rect="$2" ;;
      esac
      shift 2
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$scene" ]] || die "missing --scene <scene.pkg>"
[[ -n "$golden_dir" ]] || die "missing --golden <dir>"
[[ -n "$out_dir" ]] || die "missing --out <dir>"
[[ -n "$renderer" ]] || die "missing --renderer <binary>"
[[ -n "$assets_dir" ]] || die "missing --assets <dir>"
[[ -n "$size" ]] || die "missing --size WxH"
[[ -f "$scene" && ! -L "$scene" ]] || die "Scene package must be a regular non-symlink file: $scene"
[[ -d "$golden_dir" && ! -L "$golden_dir" ]] || die "golden directory must be a non-symlink directory: $golden_dir"
[[ -x "$renderer" && -f "$renderer" && ! -L "$renderer" ]] || die "renderer is not a regular executable: $renderer"
[[ -d "$assets_dir" && ! -L "$assets_dir" ]] || die "assets directory must be a non-symlink directory: $assets_dir"
[[ "$size" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || die "--size must be WxH with positive integers"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer"

width="${size%x*}"
height="${size#*x}"
(( width <= 4096 && height <= 4096 && width * height <= 16777216 )) \
  || die "--size exceeds the 4096x4096 / 16,777,216 pixel safety limit"

out_dir="$(be_resolve_new_output "$out_dir" "Scene golden parity report")"
if [[ -n "${BACKGROUND_ENGINE_FFMPEG:-}" ]]; then
  [[ -x "$BACKGROUND_ENGINE_FFMPEG" ]] || die "BACKGROUND_ENGINE_FFMPEG is not executable"
  PATH="$(dirname "$BACKGROUND_ENGINE_FFMPEG"):$PATH"
  export PATH
fi
be_require_tools swift ffmpeg python3 mkdir rm cp find wc tr kill sleep dirname basename
diff_script="$repo_root/Scripts/scene-frame-diff.swift"
[[ -f "$diff_script" ]] || die "missing diff script: $diff_script"

golden_frames_dir="$out_dir/golden-frames"
rendered_frames_dir="$out_dir/rendered-frames"
diffs_dir="$out_dir/diffs"
renderer_stdout="$out_dir/renderer.stdout.log"
renderer_stderr="$out_dir/renderer.stderr.log"
timeout_marker="$out_dir/.renderer-timeout"
renderer_pid=""
watchdog_pid=""
completed=0

cleanup() {
  if [[ -n "$watchdog_pid" ]]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  if [[ -n "$renderer_pid" ]]; then
    kill -TERM "$renderer_pid" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "$renderer_pid" >/dev/null 2>&1 || true
    wait "$renderer_pid" 2>/dev/null || true
  fi
  if [[ "$completed" != "1" && -d "$out_dir" ]]; then
    rm -rf "$out_dir"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$golden_frames_dir" "$rendered_frames_dir" "$diffs_dir"
golden_count="$(python3 - "$golden_dir" "$golden_frames_dir" <<'PY'
import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
frames = sorted(
    path for path in source.iterdir()
    if path.is_file() and not path.is_symlink() and path.suffix.lower() == ".png"
)
if not frames:
    print("golden directory has no regular PNG frames", file=sys.stderr)
    raise SystemExit(2)
if len(frames) > 120:
    print("golden directory exceeds the 120 frame safety limit", file=sys.stderr)
    raise SystemExit(2)
for index, frame in enumerate(frames, start=1):
    shutil.copyfile(frame, destination / f"frame_{index:05d}.png")
print(len(frames))
PY
)"

project_dir="$(dirname "$scene")"
"$renderer" \
  --window "0x0x${size}" --silent --noautomute --no-audio-processing --disable-mouse \
  --record-dir "$rendered_frames_dir" --record-seconds 1 --record-fps "$golden_count" \
  --record-exclude-live --assets-dir "$assets_dir" "$project_dir" \
  >"$renderer_stdout" 2>"$renderer_stderr" &
renderer_pid=$!
(
  sleep "$timeout_seconds"
  if kill -0 "$renderer_pid" >/dev/null 2>&1; then
    : > "$timeout_marker"
    kill -TERM "$renderer_pid" >/dev/null 2>&1 || true
    sleep 2
    kill -KILL "$renderer_pid" >/dev/null 2>&1 || true
  fi
) &
watchdog_pid=$!

set +e
wait "$renderer_pid"
renderer_status=$?
set -e
renderer_pid=""
kill "$watchdog_pid" >/dev/null 2>&1 || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""

[[ ! -f "$timeout_marker" ]] || die "renderer timed out after ${timeout_seconds}s"
[[ "$renderer_status" -eq 0 ]] || die "renderer exited with status $renderer_status (see renderer.stderr.log)"

rendered_count="$(find "$rendered_frames_dir" -type f -name 'frame_[0-9][0-9][0-9][0-9][0-9].png' | wc -l | tr -d '[:space:]')"
[[ "$rendered_count" == "$golden_count" ]] \
  || die "renderer produced $rendered_count frame(s); expected $golden_count"

for ((i = 1; i <= golden_count; i++)); do
  frame_id="$(printf '%05d' "$i")"
  golden_frame="$golden_frames_dir/frame_$frame_id.png"
  rendered_frame="$rendered_frames_dir/frame_$frame_id.png"
  [[ -f "$rendered_frame" ]] || die "missing rendered frame: $rendered_frame"
  diff_args=("$diff_script" "$golden_frame" "$rendered_frame" "--json")
  if [[ -n "$static_crop" ]]; then
    diff_args+=("--static-crop" "$static_crop")
  fi
  if [[ -n "$mask_rect" ]]; then
    diff_args+=("--mask-rect" "$mask_rect")
  fi
  if (( i > 1 )); then
    previous_id="$(printf '%05d' "$((i - 1))")"
    diff_args+=(
      "--previous-a" "$golden_frames_dir/frame_$previous_id.png"
      "--previous-b" "$rendered_frames_dir/frame_$previous_id.png"
    )
  fi
  swift "${diff_args[@]}" > "$diffs_dir/frame_$frame_id.json"
done

sheet_frame_count="$golden_count"
if (( sheet_frame_count > 12 )); then
  sheet_frame_count=12
fi
sheet_columns="$sheet_frame_count"
if (( sheet_columns > 3 )); then
  sheet_columns=3
fi
sheet_rows="$(( (sheet_frame_count + sheet_columns - 1) / sheet_columns ))"
ffmpeg -hide_banner -loglevel error -y \
  -framerate 1 -start_number 1 -i "$golden_frames_dir/frame_%05d.png" \
  -framerate 1 -start_number 1 -i "$rendered_frames_dir/frame_%05d.png" \
  -filter_complex "[0:v]scale=640:-2[golden];[1:v]scale=640:-2[rendered];[golden][rendered]hstack=inputs=2[pairs];[pairs]tile=${sheet_columns}x${sheet_rows}:nb_frames=${sheet_frame_count}[sheet]" \
  -map "[sheet]" -frames:v 1 "$out_dir/contact-sheet.png"

python3 - "$scene" "$golden_dir" "$out_dir" "$golden_count" "$sheet_frame_count" "$size" "$static_crop" "$mask_rect" <<'PY'
import json
import pathlib
import sys

scene, golden_dir, out_dir, golden_count, contact_sheet_frames, size, static_crop, mask_rect = sys.argv[1:]
out_path = pathlib.Path(out_dir)
count = int(golden_count)
diffs = []
for index in range(1, count + 1):
    with (out_path / "diffs" / f"frame_{index:05d}.json").open("r", encoding="utf-8") as handle:
        diffs.append(json.load(handle))

def mean(key):
    return sum(float(item[key]) for item in diffs) / len(diffs) if diffs else 0

summary = {
    "status": "compared",
    "scenePackage": scene,
    "goldenDirectory": golden_dir,
    "frameCount": count,
    "contactSheetFrameCount": int(contact_sheet_frames),
    "size": size,
    "staticCrop": static_crop or None,
    "maskRect": mask_rect or None,
    "contactSheet": str(out_path / "contact-sheet.png"),
    "rendererStandardOutputLog": str(out_path / "renderer.stdout.log"),
    "rendererStandardErrorLog": str(out_path / "renderer.stderr.log"),
    "diffs": diffs,
    "averageAbsDeltaMean": mean("averageAbsDelta"),
    "motionEnergyGoldenMean": mean("motionEnergyA"),
    "motionEnergyRenderedMean": mean("motionEnergyB"),
    "maxAbsDeltaMax": max((int(item["maxAbsDelta"]) for item in diffs), default=0),
    "changedRatioMean": mean("changedRatio"),
}
summary_path = out_path / "summary.json"
with summary_path.open("w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(summary_path)
PY
completed=1
