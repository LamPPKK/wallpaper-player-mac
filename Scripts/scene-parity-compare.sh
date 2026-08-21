#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$repo_root/Scripts/runtime-script-common.sh"

usage() {
  cat <<'USAGE'
usage:
  Scripts/scene-parity-compare.sh --windows <video> --mac <video> --out <dir> --size WxH [--frames N] [--start SECONDS] [--duration SECONDS] [--mac-crop W:H:X:Y] [--static-crop X,Y,W,H] [--mask-rect X,Y,W,H]

Compare two local video captures by extracting aligned PNG frames with ffmpeg,
then diffing frame pairs with Scripts/scene-frame-diff.swift --json.

options:
  --windows <video>    Windows/Wallpaper Engine capture
  --mac <video>        Mac/native renderer capture
  --out <dir>          Output directory for frames, diffs, and summary.json
  --frames N           Number of aligned frames to sample (default: 6)
  --size WxH           Required common output canvas passed to ffmpeg scale/pad
  --start SECONDS      Start offset in seconds (default: 0)
  --duration SECONDS   Sample span in seconds; 0 uses the common input span (default: 0)
  --mac-crop W:H:X:Y   Crop Mac screen recording before scaling (default: iw:ih-120:0:40)
  --static-crop RECT   Static comparison crop passed to scene-frame-diff.swift
  --mask-rect RECT     Exclude a rect, e.g. scene clock text, from metrics
  --help               Show this help
USAGE
}

die() {
  echo "scene-parity-compare: $*" >&2
  exit 2
}

need_value() {
  [[ $# -gt 1 ]] || die "missing value for $1"
}

is_nonnegative_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

windows_video=""
mac_video=""
out_dir=""
frames=6
size=""
start=0
duration=0
mac_crop="${MAC_CROP:-iw:ih-120:0:40}"
static_crop=""
mask_rect=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --windows)
      need_value "$@"
      windows_video="$2"
      shift 2
      ;;
    --mac)
      need_value "$@"
      mac_video="$2"
      shift 2
      ;;
    --out)
      need_value "$@"
      out_dir="$2"
      shift 2
      ;;
    --frames)
      need_value "$@"
      frames="$2"
      shift 2
      ;;
    --size)
      need_value "$@"
      size="$2"
      shift 2
      ;;
    --start)
      need_value "$@"
      start="$2"
      shift 2
      ;;
    --duration)
      need_value "$@"
      duration="$2"
      shift 2
      ;;
    --mac-crop)
      need_value "$@"
      mac_crop="$2"
      shift 2
      ;;
    --static-crop)
      need_value "$@"
      static_crop="$2"
      shift 2
      ;;
    --mask-rect)
      need_value "$@"
      mask_rect="$2"
      shift 2
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$windows_video" ]] || die "missing --windows <video>"
[[ -n "$mac_video" ]] || die "missing --mac <video>"
[[ -n "$out_dir" ]] || die "missing --out <dir>"
[[ -n "$size" ]] || die "missing --size WxH"
[[ -f "$windows_video" ]] || die "Windows video not found: $windows_video"
[[ -f "$mac_video" ]] || die "Mac video not found: $mac_video"
out_dir="$(be_resolve_new_output "$out_dir" "Scene parity report")"
if [[ -n "${BACKGROUND_ENGINE_FFMPEG:-}" ]]; then
  [[ -x "$BACKGROUND_ENGINE_FFMPEG" ]] || die "BACKGROUND_ENGINE_FFMPEG is not executable"
  PATH="$(dirname "$BACKGROUND_ENGINE_FFMPEG"):$PATH"
  export PATH
fi
be_require_tools ffmpeg ffprobe swift python3 mkdir rm dirname basename
[[ "$frames" =~ ^[1-9][0-9]*$ ]] || die "--frames must be a positive integer"
(( frames <= 120 )) || die "--frames exceeds the 120 frame safety limit"
[[ "$size" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || die "--size must be WxH with positive integers"
is_nonnegative_number "$start" || die "--start must be a non-negative number"
is_nonnegative_number "$duration" || die "--duration must be a non-negative number"
frame_width="${size%x*}"
frame_height="${size#*x}"
(( frame_width <= 4096 && frame_height <= 4096 && frame_width * frame_height <= 16777216 )) \
  || die "--size exceeds the 4096x4096 / 16,777,216 pixel safety limit"

diff_script="$repo_root/Scripts/scene-frame-diff.swift"
[[ -f "$diff_script" ]] || die "missing diff script: $diff_script"

windows_dir="$out_dir/windows-frames"
mac_dir="$out_dir/mac-frames"
diffs_dir="$out_dir/diffs"
completed=0
cleanup() {
  if [[ "$completed" != "1" && -d "$out_dir" ]]; then
    rm -rf "$out_dir"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$windows_dir" "$mac_dir" "$diffs_dir"

probe_duration() {
  ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1"
}

probe_metadata() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,avg_frame_rate,sample_aspect_ratio,display_aspect_ratio:format=duration \
    -of json "$1"
}

windows_duration="$(probe_duration "$windows_video")"
mac_duration="$(probe_duration "$mac_video")"
windows_metadata="$(probe_metadata "$windows_video")"
mac_metadata="$(probe_metadata "$mac_video")"
sample_duration="$duration"
if [[ "$sample_duration" =~ ^0+([.]0+)?$ ]]; then
  sample_duration="$(
    python3 - "$start" "$windows_duration" "$mac_duration" <<'PY'
import math
import sys

start = float(sys.argv[1])
durations = []
for raw in sys.argv[2:]:
    try:
        value = float(raw)
    except ValueError:
        continue
    if math.isfinite(value) and value > start:
        durations.append(value - start)
print(max(min(durations), 0.001) if durations else 1)
PY
  )"
fi

python3 - "$start" "$duration" "$sample_duration" "$windows_duration" "$mac_duration" <<'PY'
import math
import sys

start = float(sys.argv[1])
requested_duration = float(sys.argv[2])
sample_duration = float(sys.argv[3])
durations = []
for label, raw in (("Windows", sys.argv[4]), ("Mac", sys.argv[5])):
    try:
        value = float(raw)
    except ValueError:
        continue
    if not math.isfinite(value):
        continue
    if value < 15:
        print(
            f"scene-parity-compare: warning: {label} capture is {value:.3f}s; v3 fixed-scene protocol expects >=15s",
            file=sys.stderr,
        )
    if value <= start:
        print(f"scene-parity-compare: {label} video ends before --start {start:g}s", file=sys.stderr)
        sys.exit(2)
    durations.append(value)

if durations:
    shortest = min(durations)
    if requested_duration > 0 and start + sample_duration > shortest + 0.000001:
        print(
            f"scene-parity-compare: requested sample ends at {start + sample_duration:.3f}s, past shorter input {shortest:.3f}s",
            file=sys.stderr,
        )
        sys.exit(2)
PY

extract_frames() {
  local input="$1"
  local target_dir="$2"
  local prefix_filter="$3"
  local filter=""
  if [[ -n "$prefix_filter" ]]; then
    filter="${prefix_filter},"
  fi
  ffmpeg -hide_banner -loglevel error -y \
    -ss "$start" \
    -i "$input" \
    -t "$sample_duration" \
    -vf "${filter}fps=${frames}/${sample_duration},scale=${frame_width}:${frame_height}:force_original_aspect_ratio=decrease:flags=bicubic,pad=${frame_width}:${frame_height}:(ow-iw)/2:(oh-ih)/2:black" \
    -frames:v "$frames" \
    "$target_dir/frame-%03d.png"
}

extract_frames "$windows_video" "$windows_dir" ""
extract_frames "$mac_video" "$mac_dir" "crop=${mac_crop}"

for ((i = 1; i <= frames; i++)); do
  frame_id="$(printf '%03d' "$i")"
  win_frame="$windows_dir/frame-$frame_id.png"
  mac_frame="$mac_dir/frame-$frame_id.png"
  [[ -f "$win_frame" ]] || die "missing extracted Windows frame: $win_frame"
  [[ -f "$mac_frame" ]] || die "missing extracted Mac frame: $mac_frame"
  diff_args=("$diff_script" "$win_frame" "$mac_frame" "--json")
  if [[ -n "$static_crop" ]]; then
    diff_args+=("--static-crop" "$static_crop")
  fi
  if [[ -n "$mask_rect" ]]; then
    diff_args+=("--mask-rect" "$mask_rect")
  fi
  if (( i > 1 )); then
    previous_id="$(printf '%03d' "$((i - 1))")"
    diff_args+=("--previous-a" "$windows_dir/frame-$previous_id.png" "--previous-b" "$mac_dir/frame-$previous_id.png")
  fi
  swift "${diff_args[@]}" > "$diffs_dir/frame-$frame_id.json"
done

sheet_frame_count="$frames"
if (( sheet_frame_count > 12 )); then
  sheet_frame_count=12
fi
sheet_columns="$sheet_frame_count"
if (( sheet_columns > 3 )); then
  sheet_columns=3
fi
sheet_rows="$(( (sheet_frame_count + sheet_columns - 1) / sheet_columns ))"
ffmpeg -hide_banner -loglevel error -y \
  -framerate 1 -i "$windows_dir/frame-%03d.png" \
  -framerate 1 -i "$mac_dir/frame-%03d.png" \
  -filter_complex "[0:v]scale=640:-2[windows];[1:v]scale=640:-2[mac];[windows][mac]hstack=inputs=2[pairs];[pairs]tile=${sheet_columns}x${sheet_rows}:nb_frames=${sheet_frame_count}[sheet]" \
  -map "[sheet]" -frames:v 1 "$out_dir/contact-sheet.png"

python3 - "$windows_video" "$mac_video" "$out_dir" "$frames" "$sheet_frame_count" "$size" "$start" "$sample_duration" "$mac_crop" "$static_crop" "$mask_rect" "$windows_metadata" "$mac_metadata" <<'PY'
import json
import pathlib
import sys

windows_video, mac_video, out_dir, frames, contact_sheet_frames, size, start, sample_duration, mac_crop, static_crop, mask_rect, windows_metadata, mac_metadata = sys.argv[1:]
out_path = pathlib.Path(out_dir)
frame_count = int(frames)
diffs = []
for index in range(1, frame_count + 1):
    diff_path = out_path / "diffs" / f"frame-{index:03d}.json"
    with diff_path.open("r", encoding="utf-8") as handle:
        diffs.append(json.load(handle))

def mean(key):
    return sum(float(item[key]) for item in diffs) / len(diffs) if diffs else 0

summary = {
    "windowsVideo": windows_video,
    "macVideo": mac_video,
    "windowsMetadata": json.loads(windows_metadata),
    "macMetadata": json.loads(mac_metadata),
    "frameCount": frame_count,
    "contactSheetFrameCount": int(contact_sheet_frames),
    "size": size,
    "start": float(start),
    "duration": float(sample_duration),
    "macCrop": mac_crop,
    "staticCrop": static_crop or None,
    "maskRect": mask_rect or None,
    "contactSheet": str(out_path / "contact-sheet.png"),
    "diffs": diffs,
    "averageAbsDeltaMean": mean("averageAbsDelta"),
    "staticCropAverageDeltaRMean": mean("staticCropAverageDeltaR"),
    "staticCropAverageDeltaGMean": mean("staticCropAverageDeltaG"),
    "staticCropAverageDeltaBMean": mean("staticCropAverageDeltaB"),
    "motionEnergyAMean": mean("motionEnergyA"),
    "motionEnergyBMean": mean("motionEnergyB"),
    "brightHighlightClusterCountAMean": mean("brightHighlightClusterCountA"),
    "brightHighlightClusterCountBMean": mean("brightHighlightClusterCountB"),
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
