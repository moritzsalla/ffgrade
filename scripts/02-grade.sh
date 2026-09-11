#!/bin/bash
# Stage 2: baseline -> graded master (Portra look + tone shaping + the chosen look).
# Usage: ./02-grade.sh IMG_XXXX
# Reads dist/01-baseline/<clip>_baseline.mov, writes dist/02-graded/<clip>_graded.mov.
#
# THE TONE LUT IS THE POINT. The Portra LUT alone leaves the image far too bright and flat
# ("milky"): nothing reaches black and the whole frame sits ~25% too high. shipped.cube fixes that.
# Don't drop it thinking it's redundant — see docs/PIPELINE.md, "Tone shaping".
#
# WHY mergeplanes: the tone curve is applied to the LUMA PLANE ONLY, with the original chroma
# merged back. A per-channel contrast curve crushes a saturated colour's two low channels harder
# than its high one, which turns traffic signage neon — visible on the 30 km/h ring long before it
# was measured. Luma-only gives identical tone with chroma untouched. `format=yuv444p10le` on both
# branches is required; without it mergeplanes fails with a bare "Invalid argument".
#
# The saturation and warmth below are a CREATIVE choice made by eye in the Grade Bench, not a
# correction. Measured against the standardised colours in frame, the Apple CST's own colour is
# already accurate (traffic blue lands at B/G 1.99 against a 1.98 spec with nothing applied). The
# values here deliberately depart from that. Change them because the look should change, never
# because a reading looks "wrong" — being off-spec here is the intent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CLIP="$1"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE="$ROOT/dist/01-baseline/${CLIP}_baseline.mov"
LUT="$ROOT/luts/looks/kodak_portra_400_nc.cube"
TONE="$ROOT/luts/tone/shipped.cube"
# Graded by eye in the Grade Bench (bench), calibrated live against the RAL references in
# frame, then sent back through the artifact db. Deliberately off-spec: saturation 1.27 puts the
# traffic blue at B/G 2.39 against a 1.98 spec. That is a grade, not an error — accuracy is the
# reference you depart from on purpose. Regenerate shipped.cube with:
#   ./make-tone-lut.py ../../luts/tone/shipped.cube --gamma 2.02 --pivot 0.39 --contrast 1.09 \
#                      --toe 0.00 --shoulder 0.10 --black 0.025
# (v2, after review: black point lifted 0.015 -> 0.025 and gamma eased 2.09 -> 2.02 to open
#  shadow detail. `toe` was measured to do NOTHING at pivot 0.39 — identical percentiles at 0.07
#  and 0.00 — so it is zeroed rather than left as a decorative knob. The black point is the live
#  shadow control here.)
SAT="1.27"
WARM="0.005"
OUT="$ROOT/dist/02-graded/${CLIP}_graded.mov"

[ -f "$BASELINE" ] || { echo "baseline not found: $BASELINE — run 01-baseline.sh first" >&2; exit 1; }
check_disk_space "$ROOT/dist" 10

ffmpeg -y -i "$BASELINE" \
	-filter_complex "[0:v]lut3d=file='${LUT}':interp=tetrahedral,format=yuv444p10le,split=2[a][b];\
[a]lut1d=file='${TONE}':interp=linear,format=yuv444p10le[t];\
[t][b]mergeplanes=0x001112:yuv444p10le,hue=s=${SAT},colorbalance=rm=${WARM}:bm=-${WARM}[o]" \
	-map "[o]" -map "0:a:0?" \
	-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
	-c:a copy \
	"$OUT" -v error

require_nonempty "$OUT" "grade encode"
safe_retag "$OUT"
echo "done: $OUT"
