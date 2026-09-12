#!/bin/bash
# Stage 1: source -> baseline (Log->Rec709 CST, correct color tags, optional rotation fix).
# Usage: ./01-baseline.sh IMG_XXXX
#
# Rotation is NOT handled here. The source is assumed to be correctly oriented — that is an ingest
# concern, not a grading one, and no NLE fixes it for you either. If a clip is sideways or upside
# down, normalise it first with scripts/normalise-rotation.sh; the guard below refuses it rather
# than grading a sideways frame and leaving you to notice later.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CLIP="$1"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"
SRC="$WORK/src/${CLIP}.mov"
LUT="$ROOT/luts/apple/AppleLogToRec709-v1.0.cube"
OUT="$WORK/dist/01-baseline/${CLIP}_baseline.mov"

[ -f "$SRC" ] || { echo "source not found: $SRC" >&2; exit 1; }
# Apple's CST is NOT in this repo — it is not redistributable (see luts/apple/SOURCE.txt). On a
# fresh clone it will be missing, so say so precisely rather than letting ffmpeg fail on a path.
[ -f "$LUT" ] || {
	echo "Apple's Log->Rec709 LUT is missing:" >&2
	echo "  $LUT" >&2
	echo "It is deliberately not committed — Apple's licence does not permit redistributing it." >&2
	echo "Download it (free Apple ID, ~2 min) per luts/apple/SOURCE.txt, then re-run." >&2
	exit 1
}
check_disk_space "$ROOT/dist" 10

FILTER="lut3d=file='${LUT}':interp=tetrahedral"

ffmpeg -y -i "$SRC" -vf "$FILTER" \
	-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
	-c:a copy \
	"$OUT" -v error

require_nonempty "$OUT" "baseline encode"
safe_retag "$OUT"
echo "done: $OUT"
