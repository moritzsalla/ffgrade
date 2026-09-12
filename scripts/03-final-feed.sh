#!/bin/bash
# Stage 3b: graded master -> Feed post delivery (4:5, 1080x1350).
# Usage: ./03-final-feed.sh IMG_XXXX [CROP_Y]
#   CROP_Y: vertical crop offset (pixels, on the 2160x3840 master) — where the 2160x2700 crop
#           window starts. Default 750 is IMG_0609's biased-up crop (removes the parking-ceiling
#           strip at top, keeps ivy + a bit more road at bottom). NOT assumed correct for every
#           clip's composition — eyeball a crop preview per clip and pass the right offset.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CLIP="$1"
SMOOTHING="${SMOOTHING:-$(look .stabilisation.smoothing)}"   # frames of camera-path lowpass; higher = closer to locked-off
CROP_Y="${2:-750}"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"
IN="$WORK/dist/02-graded/${CLIP}_graded.mov"
OUT="$WORK/dist/03-final/${CLIP}_feed_4x5.mp4"

[ -f "$IN" ] || { echo "graded master not found: $IN — run 02-grade.sh first" >&2; exit 1; }
check_disk_space "$ROOT/dist" 2
require_portrait "$IN"   # refuses landscape rather than cropping past the frame edge


# --- optional stabilisation -------------------------------------------------
# If dist/stab/<clip>.trf exists (produced by 00-stabilise-detect.sh), the sway is smoothed out
# before the downscale, so the warp resamples at full resolution rather than at delivery size.
# This also fixes a second problem: handheld sway slides high-contrast edges across the chroma
# sampling grid, so chroma fringing PHASE-SHIFTS frame to frame and reads as a shimmer along the
# street-sign lettering. Holding the frame still stops the shimmer moving; hqdn3d below removes
# what remains.
STAB=""
TRF="$WORK/dist/stab/${CLIP}.trf"
if [ -f "$TRF" ]; then
	STAB="vidstabtransform=input='${TRF}':smoothing=${SMOOTHING}:optzoom=1:interpol=bicubic,unsharp=5:5:0.2:3:3:0.0,"
	echo "stabilising with $TRF (smoothing=${SMOOTHING})"
else
	echo "no transforms at $TRF — rendering unstabilised (run 00-stabilise-detect.sh first)"
fi

# --- chroma-only denoise ----------------------------------------------------
# hqdn3d=<luma_spatial>:<chroma_spatial>:<luma_tmp>:<chroma_tmp>. Luma terms are ZERO on purpose:
# this must not touch image detail. It exists because saturation 1.27 amplifies the chroma error
# already present on high-contrast edges (measured: the street sign's white-on-blue lettering
# gains a visible cyan fringe between baseline and graded), and the 4:2:0 conversion at export
# coarsens it further. Verified chroma-only: luma YAVG 486.97 -> 487.02.
CHROMA="hqdn3d=0:5:0:6,"


# --- film grain -------------------------------------------------------------
# CLUSTERED grain, not per-pixel, and applied AFTER the sharpener. Both were measured:
#
#   1. Grain before `unsharp` gets RUNG by the sharpener — the isolated grain residual shows a
#      negative lag-1 autocorrelation (-0.09), the signature of an overshoot either side of every
#      spike, which is what reads as "crunchy digital" rather than film. It is also WEAKER than
#      intended (sd 2.65 vs 3.67 at the same c0s) because the sharpener averages it away. Ordering
#      grain last is strictly better and costs nothing.
#   2. Per-pixel grain does not survive delivery. Re-encoded at ~4 Mbps (Instagram territory) its
#      lag-1 goes 0.00 -> 0.39: the compressor smears it into blobs and invents correlation that
#      was never there. Grain generated at half resolution and upscaled keeps its own structure
#      through the same re-encode (0.75 -> 0.59).
#   3. Clustered is also CHEAPER: bitrate vs no grain is 3.7x per-pixel, 2.9x clustered. More
#      filmic and ~22% cheaper to encode, which is not the usual trade.
#      (`-tune grain` was tested too: 4.3x bitrate for no structural gain. Skipped.)
#
# Dither happens at the 10->8 bit reduction (on the image branch), NOT after the blend: the
# lavfi grey plate carries no colourspace metadata, so a zscale placed after `blend` has no
# input space to convert from and dies with "code 3074: no path between colorspaces". The
# grain plate is already 8-bit, so dithering it again bought nothing anyway.
#
# Generated on a flat grey plate whose chroma stays neutral, so `grainmerge` is a no-op on the
# chroma planes — measured U-plane residual sd 0.000, i.e. verifiably luma-only. That matters here
# because the hqdn3d pass above exists to clean chroma up; grain must not put any back.
#
# c0s is the one number that wants an eye rather than a measurement. 8 reads as "subtle";
# clustered grain reads stronger per unit amplitude than per-pixel, so it sits below the old 6.
# `blend=...:shortest=1` is REQUIRED, and `-shortest` is not a substitute. The grey plate is an
# infinite lavfi source; with filter_complex, `-shortest` does not reliably stop the encode, so
# the render runs forever and the output file grows without bound (observed: a 26s clip past
# 189MB and still going, with no moov atom ever written). The blend option terminates on the
# shortest input, which is the video.
#
# The grain plate MUST be tagged before the blend. A `lavfi` source carries no colourspace
# metadata, and ffmpeg negotiates formats across the WHOLE graph — so an untagged branch
# propagates "unknown" backwards and the zscale on the IMAGE branch then fails with
# "code 3074: no path between colorspaces", pointing at a filter that is not the problem.
# Every filter here was bisected individually and all passed; only the pair fails.
GRAIN_STRENGTH="${GRAIN_STRENGTH:-$(look .grain.strength)}"
FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$IN" | head -1)
[ -n "$FPS" ] || FPS="24"

ffmpeg -y -i "$IN" -f lavfi -i "color=c=gray:s=540x675:r=${FPS}" \
	-filter_complex "[0:v]${STAB}${CHROMA}crop=2160:2700:0:${CROP_Y},zscale=w=1080:h=1350:f=lanczos:d=error_diffusion,format=yuv420p,unsharp=5:5:0.4:5:5:0.0[b];\
[1:v]noise=c0s=${GRAIN_STRENGTH}:c0f=t,scale=1080:1350:flags=bilinear,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=limited[g];\
[b][g]blend=all_mode=grainmerge:shortest=1[o]" \
	-map "[o]" -map "0:a:0?" -shortest \
	-c:v libx264 -profile:v high -preset slow -crf 18 \
	-color_primaries bt709 -color_trc bt709 -colorspace bt709 \
	-c:a aac -b:a 192k \
	-movflags +faststart \
	"$OUT" -v error

require_nonempty "$OUT" "feed encode"
safe_retag "$OUT" -movflags +faststart
echo "done: $OUT"
