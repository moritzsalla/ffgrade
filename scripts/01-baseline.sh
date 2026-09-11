#!/bin/bash
# Stage 1: source -> baseline (Log->Rec709 CST, correct color tags, optional rotation fix).
# Usage: ./01-baseline.sh IMG_XXXX [ROTATE_FIX]
#   ROTATE_FIX: "none" (default) — trust ffmpeg's autorotate against the file's own display
#               matrix, which is correct for most clips — or "180" if a preview check shows the
#               autorotated result is upside down anyway (seen once, on IMG_0609; NOT assumed to
#               apply to every clip — see docs/PIPELINE.md and BATCH-RUNBOOK.md).
# DO NOT default this to "180" in a batch loop — confirm per clip with a preview frame first.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CLIP="$1"
ROTATE_FIX="${2:-none}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/src/${CLIP}.mov"
LUT="$ROOT/luts/apple/AppleLogToRec709-v1.0.cube"
OUT="$ROOT/dist/01-baseline/${CLIP}_baseline.mov"

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
if [ "$ROTATE_FIX" = "180" ]; then
	FILTER="${FILTER},vflip,hflip"
elif [ "$ROTATE_FIX" != "none" ]; then
	echo "unknown ROTATE_FIX '$ROTATE_FIX' — use 'none' or '180'" >&2
	exit 1
fi

ffmpeg -y -i "$SRC" -vf "$FILTER" \
	-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
	-c:a copy \
	"$OUT" -v error

require_nonempty "$OUT" "baseline encode"
safe_retag "$OUT"
echo "done: $OUT"
