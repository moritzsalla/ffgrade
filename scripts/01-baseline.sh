#!/bin/bash
# Stage 1: source -> baseline (Log->Rec709 CST, correct color tags, optional rotation fix).
# Usage: ./01-baseline.sh IMG_XXXX [ROTATE_FIX]
#   ROTATE_FIX:
#     none  (default) trust ffmpeg's autorotate against the file's own display matrix
#     cw    rotate 90 clockwise — for clips stored WITHOUT a rotation matrix
#     ccw   rotate 90 counter-clockwise
#     180   flip, when autorotate lands upside down (seen on the one +90 clip)
#
# The rotation CLASS is readable from the file, so this does not need eyeballing per clip:
#   matrix -90  -> autorotate is correct, use "none"
#   matrix +90  -> autorotate lands upside down, use "180"
#   NO matrix   -> the file is portrait content stored as landscape with the flag missing
#                  entirely. ffmpeg has nothing to autorotate by, so it stays sideways. Use "cw".
#
# That last class was originally mistaken for "landscape footage" and treated as a framing problem
# needing a crop decision. It is not: the content is portrait, the flag is just absent. Confirmed
# by rendering five of them.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CLIP="$1"
ROTATE_FIX="${2:-none}"
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
case "$ROTATE_FIX" in
	none) ;;
	cw)   FILTER="${FILTER},transpose=1" ;;
	ccw)  FILTER="${FILTER},transpose=2" ;;
	180)  FILTER="${FILTER},vflip,hflip" ;;
	*)    echo "unknown ROTATE_FIX '$ROTATE_FIX' — use none, cw, ccw or 180" >&2; exit 1 ;;
esac

ffmpeg -y -i "$SRC" -vf "$FILTER" \
	-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
	-c:a copy \
	"$OUT" -v error

require_nonempty "$OUT" "baseline encode"
safe_retag "$OUT"
echo "done: $OUT"
