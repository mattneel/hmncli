#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$repo_root/tests/fixtures/real/tonc"
capture_script="$repo_root/scripts/mgba_capture_tonc.lua"

if ! python3 - <<'PY' >/dev/null 2>&1
import PIL  # noqa: F401
PY
then
  echo "python3 with Pillow is required to convert mGBA PNG output to raw RGBA" >&2
  exit 1
fi

mgba_headless="$("$repo_root/scripts/build-mgba-headless.sh")"

scratch_root="$repo_root/.zig-cache/tonc-goldens"
mkdir -p "$scratch_root"
workdir="$(mktemp -d "$scratch_root/run.XXXXXX")"

cleanup() {
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    rm -rf "$workdir"
  else
    echo "tonc golden regeneration scratch preserved at $workdir" >&2
  fi
}
trap cleanup EXIT

capture_demo() {
  local demo_name="$1"
  local stop_frames="$2"
  local key_mask="$3"
  local output_raw="$fixture_dir/$demo_name.golden.rgba"
  local output_png="$workdir/$demo_name.png"
  local log_path="$workdir/$demo_name.log"

  local run_status=0
  set +e
  HM_MGBA_OUTPUT_PNG="$output_png" \
  HM_MGBA_STOP_FRAMES="$stop_frames" \
  HM_MGBA_KEY_MASK="$key_mask" \
    timeout 2s "$mgba_headless" -l 0 -C logToStdout=0 --script "$capture_script" \
      "$fixture_dir/$demo_name.gba" >"$log_path" 2>&1
  run_status=$?
  set -e

  if [ "$run_status" -ne 0 ] && [ "$run_status" -ne 124 ]; then
    echo "mGBA capture failed for $demo_name; see $log_path" >&2
    exit 1
  fi

  if [ ! -f "$output_png" ]; then
    echo "mGBA did not produce $output_png for $demo_name; see $log_path" >&2
    exit 1
  fi

  python3 - "$output_png" "$output_raw" <<'PY'
import sys
from pathlib import Path
from PIL import Image

png_path = Path(sys.argv[1])
raw_path = Path(sys.argv[2])

image = Image.open(png_path).convert("RGBA")
raw_path.write_bytes(image.tobytes())
if image.size != (240, 160):
    raise SystemExit(f"unexpected PNG size {image.size} for {png_path}")
PY

  if [ "$(wc -c <"$output_raw")" -ne 153600 ]; then
    echo "unexpected raw size for $output_raw" >&2
    exit 1
  fi

  printf '%s %s\n' "$(sha256sum "$output_raw" | awk '{print $1}')" "$output_raw"
}

capture_demo "sbb_reg" 60 0
capture_demo "obj_demo" 60 0
capture_demo "key_demo" 60 1
