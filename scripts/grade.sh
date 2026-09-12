#!/bin/bash
# grade — one clip, one ffmpeg pass, source to deliverable.
#
# Usage:
#   ./scripts/grade <folder|clip.mov> [...]      process a shoot folder or named clips
#   FEED=1 ./scripts/grade <folder>              also emit the 4:5 Feed crop
#   STAB=0 ./scripts/grade <folder>              skip stabilisation (faster)
#   DRY=1  ./scripts/grade <folder>              plan only, render nothing
#
# WHY ONE PASS. The staged pipeline (01-baseline -> 02-grade -> 03-final) writes two ~2.5GB ProRes
# intermediates per clip and decodes the footage three times. Those intermediates existed so the
# look could be re-tuned without redoing the CST. The look is now FROZEN, so they earn nothing:
# nothing ever re-renders from the master. Collapsing to a single filter graph removes two full
# encodes, two full decodes and ~5GB of disk per clip. The staged scripts are kept for re-tuning
# and for the Bench; this is the path for production runs.
#
# WHAT IS STILL AUTOMATIC vs WHAT THIS REFUSES TO GUESS:
#   automatic  rotation class, exposure match, stabilisation, the whole grade, tag verification
#   refuses    only genuinely unexpected rotations; the Feed crop offset stays a per-clip call
#
# EXPOSURE MATCHING is the part that makes "one recipe" actually mean "one look". The grade was
# tuned on a single frame of IMG_0609, ~20 minutes before sunset. Golden hour moves fast; clips
# shot across a shoot window land differently under a fixed curve, and in an unattended batch
# nobody notices until the edit. Each clip's post-CST mean is measured and the tone curve's gamma
# is solved per clip to land on the same place. Disable with MATCH=0 to get the frozen curve raw.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(resolve_work_dir "$ROOT")"

CST="$ROOT/luts/apple/AppleLogToRec709-v1.0.cube"
LOOK="$ROOT/luts/looks/kodak_portra_400_nc.cube"
OUT_DIR="$WORK/dist/03-final"
# Reports are not deliverables — keep them out of the folder someone uploads from.
REPORT_DIR="$WORK/dist/reports"
WORK="$WORK/dist/.grade-work"

# --- the frozen look. Change these only to change the look for every clip, everywhere. ---
SAT="$(look .colour.saturation)"; WARM="$(look .colour.warmth)"
G_PIVOT="0.39"; G_CONTRAST="1.09"; G_TOE="0.00"; G_SHOULDER="0.10"; G_BLACK="0.025"
G_GAMMA_REF="2.02"          # gamma the look was tuned at...
Y_REF="609"                 # ...against this post-CST mean (10-bit), measured on IMG_0609
GRAIN="${GRAIN:-$(look .grain.strength)}"; SMOOTHING="${SMOOTHING:-$(look .stabilisation.smoothing)}"
STAB="${STAB:-1}"; FEED="${FEED:-0}"; MATCH="${MATCH:-1}"; DRY="${DRY:-0}"
SP="setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=limited"

mkdir -p "$OUT_DIR" "$REPORT_DIR" "$WORK"
REPORT="$REPORT_DIR/run-$(date +%Y%m%d-%H%M%S).txt"
: > "$REPORT"
say() { echo "$*" | tee -a "$REPORT"; }

# Collect inputs: folders expand to their .mov files.
CLIPS=()
for arg in "$@"; do
	if [ -d "$arg" ]; then
		while IFS= read -r f; do CLIPS+=("$f"); done < <(find "$arg" -maxdepth 1 -name '*.mov' | sort)
	elif [ -f "$arg" ]; then CLIPS+=("$arg")
	else echo "not found: $arg" >&2; exit 1; fi
done
[ "${#CLIPS[@]}" -gt 0 ] || { echo "usage: grade <folder|clip.mov> [...]" >&2; exit 1; }

say "grade run $(date '+%Y-%m-%d %H:%M:%S')  —  ${#CLIPS[@]} clip(s)"
say "look: sat=$SAT warm=$WARM grain=$GRAIN stab=$STAB exposure-match=$MATCH"
say ""

OK=0; SKIPPED=0
for SRC in "${CLIPS[@]}"; do
	CLIP="$(basename "${SRC%.*}")"

	# --- rotation class. The matrix predicts it; no eyeballing needed. -------------------
	# `|| true` is load-bearing: grep exits 1 when a clip has NO rotation matrix, and under
	# `set -e` that aborts the whole run on the first such clip, silently, with exit 1 and no
	# message. Most of this shoot has no matrix, so it fails on clip one.
	#
	# A MISSING matrix does not mean landscape footage. It means portrait content stored as
	# 3840x2160 with the flag absent — ffmpeg has nothing to autorotate by, so the frame stays
	# sideways, and a sideways portrait frame reads as a landscape composition. These clips were
	# skipped as "needing a framing decision" for a while; they need transpose=1 and nothing else.
	# Confirmed by rendering five of them. See docs/BATCH_RUNBOOK.md, "Mixed orientation".
	ROT=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=rotation \
		-of csv=p=0 "$SRC" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1 || true)
	case "${ROT:-none}" in
		90)   FIX=",vflip,hflip" ;;   # +90: autorotate lands it upside down
		-90)  FIX="" ;;               # -90: autorotate alone is correct
		none) FIX=",transpose=1" ;;   # no matrix: portrait stored as landscape
		*)    say "SKIP  $CLIP — unexpected rotation '$ROT'"; SKIPPED=$((SKIPPED+1)); continue ;;
	esac

	# --- exposure match: one cheap probe, not a full pass --------------------------------
	GAMMA="$G_GAMMA_REF"; YAVG="-"
	if [ "$MATCH" = "1" ]; then
		YAVG=$(ffmpeg -v error -ss 1 -i "$SRC" -frames:v 1 \
			-vf "lut3d=file='${CST}':interp=tetrahedral${FIX},scale=320:-1,signalstats,metadata=print:file=-" \
			-f null - 2>/dev/null | grep -m1 -oE 'YAVG=[0-9.]+' | cut -d= -f2 || true)
		# `metadata=print:file=-` not plain `metadata=print`: the latter logs at INFO level, which
		# `-v error` suppresses, so the probe returned EMPTY on every clip and every clip silently
		# got the reference gamma. The exposure match appeared to run and did nothing.
		if [ -n "$YAVG" ]; then
			GAMMA=$(python3 -c "
import math
y=float('$YAVG')/1023.0; r=float('$Y_REF')/1023.0; g=float('$G_GAMMA_REF')
# solve x_new^g_new = x_ref^g_ref so every clip lands where the look was tuned
print('%.3f' % max(1.2, min(3.2, g*math.log(r)/math.log(y))))")
		fi
	fi

	TONE="$WORK/${CLIP}_tone.cube"
	"$SCRIPT_DIR/make-tone-lut.py" "$TONE" --gamma "$GAMMA" --pivot "$G_PIVOT" \
		--contrast "$G_CONTRAST" --toe "$G_TOE" --shoulder "$G_SHOULDER" --black "$G_BLACK" >/dev/null

	# --- stabilisation: detect on the SOURCE, so no intermediate is needed ---------------
	SFX=""
	if [ "$STAB" = "1" ]; then
		TRF="$WORK/dist/stab/${CLIP}.trf"
		if [ ! -f "$TRF" ] && [ "$DRY" != "1" ]; then
			mkdir -p "$(dirname "$TRF")"
			ffmpeg -v error -y -i "$SRC" -vf "lut3d=file='${CST}':interp=tetrahedral${FIX},vidstabdetect=shakiness=5:accuracy=15:stepsize=6:result=${TRF}.partial" -f null -
			mv "${TRF}.partial" "$TRF"
		fi
		[ -f "$TRF" ] && SFX="vidstabtransform=input='${TRF}':smoothing=${SMOOTHING}:optzoom=1:interpol=bicubic,unsharp=5:5:0.2:3:3:0.0,"
	fi

	say "$CLIP  rot=${ROT:-none}  post-CST YAVG=${YAVG}  gamma=${GAMMA}$([ "$GAMMA" != "$G_GAMMA_REF" ] && echo " (matched)")"
	[ "$DRY" = "1" ] && continue

	render() {  # render <w> <h> <suffix> [crop]
		local w=$1 h=$2 suffix=$3 crop=${4:-}
		local out="$OUT_DIR/${CLIP}_${suffix}.mp4"
		ffmpeg -y -i "$SRC" -f lavfi -i "color=c=gray:s=$((w/2))x$((h/2)):r=24" -filter_complex \
"[0:v]lut3d=file='${CST}':interp=tetrahedral${FIX},lut3d=file='${LOOK}':interp=tetrahedral,\
format=yuv444p10le,split=2[a][b2];\
[a]lut1d=file='${TONE}':interp=linear,format=yuv444p10le[t];\
[t][b2]mergeplanes=0x001112:yuv444p10le,${SP},hue=s=${SAT},colorbalance=rm=${WARM}:bm=-${WARM},\
${SFX}hqdn3d=0:5:0:6,${crop}zscale=w=${w}:h=${h}:f=lanczos:d=error_diffusion,format=yuv420p,\
unsharp=5:5:0.4:5:5:0.0[b];\
[1:v]noise=c0s=${GRAIN}:c0f=t,scale=${w}:${h}:flags=bilinear,format=yuv420p,${SP}[g];\
[b][g]blend=all_mode=grainmerge:shortest=1[o]" \
			-map "[o]" -map 0:a:0? \
			-c:v libx264 -profile:v high -preset slow -crf 18 \
			-color_primaries bt709 -color_trc bt709 -colorspace bt709 \
			-c:a aac -b:a 192k -movflags +faststart "$out" -v error
		require_nonempty "$out" "$suffix encode"
		safe_retag "$out" -movflags +faststart >/dev/null
		say "      -> $(basename "$out")  $(( $(stat -f%z "$out") / 1048576 ))MB"
	}

	render 1080 1920 "reels-stories_9x16"
	[ "$FEED" = "1" ] && render 1080 1350 "feed_4x5" "crop=2160:2700:0:${CROP_Y:-750},"
	OK=$((OK+1))
done

say ""
say "done: $OK rendered, $SKIPPED skipped"
say "report: $REPORT"
