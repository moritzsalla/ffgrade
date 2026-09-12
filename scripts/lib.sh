#!/bin/bash
# Shared safety helpers for every stage script. Source this, don't copy it —
# the retag/verify pattern exists because both mistakes below actually happened once:
#
#   1. prores_ks (and libx264) don't reliably stamp -color_primaries/-color_trc/-colorspace
#      mid-encode. A file can measure bt2020 tags after encode despite those flags being passed,
#      even though the pixels were already correctly transformed — any tag-trusting player then
#      double-transforms the image (this is the "bleached out" bug). Fix: always re-verify with
#      ffprobe after ANY encode step in this pipeline, and re-tag via a fast -c copy remux if wrong.
#   2. -map 0 copies every stream, including ones the target container can't hold (a ProRes .mov's
#      QuickTime timecode data track has no mp4 equivalent) — that remux fails, and if the
#      following `mv` isn't conditional on success, it moves the failed (0-byte) output over a
#      good file, destroying it. This happened for real and cost one full re-render.
#
# Every stage script below must: encode -> check output is non-empty -> verify/fix tags via
# explicit stream mapping -> mv only after confirming the retag succeeded.

set -euo pipefail

# Resolved relative to lib.sh itself, so every stage sees the same file regardless of cwd.
LOOK_FILE="${LOOK_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/look.json}"

# ffprobe reports the video stream TWICE on these files (once inside [STREAM_GROUP], once as a
# top-level [STREAM]) plus a blank separator line — so this reads the first non-empty line rather
# than comparing the whole multi-line output against one expected value. An earlier version of
# this function compared the raw output directly and therefore false-failed on every correctly
# tagged file.
probe_tags() {
	ffprobe -v error -select_streams v:0 \
		-show_entries stream=color_space,color_transfer,color_primaries \
		-of csv=p=0 "$1" | grep -v '^[[:space:]]*$' | head -1
}

verify_bt709() {
	local file="$1"
	local tags
	tags=$(probe_tags "$file")
	if [ "$tags" != "bt709,bt709,bt709" ]; then
		echo "TAG CHECK FAILED for $file: got '$tags', expected bt709,bt709,bt709" >&2
		return 1
	fi
	echo "tags OK ($file): $tags"
}

# Re-tags a file in place via a fast -c copy remux. Never overwrites the original unless the
# remux actually succeeded and produced a non-empty file.
#
# Takes the file, then any extra ffmpeg output args (e.g. -movflags +faststart). Uses "$@"
# directly rather than an intermediate array: macOS ships bash 3.2, where expanding an EMPTY
# array under `set -u` raises "unbound variable" — which silently blocked every retag until it
# was found. "$@" with no remaining positional args expands to nothing, safely, on 3.2.
safe_retag() {
	local file="$1"
	shift
	local tmp="${file%.*}_tagged.${file##*.}"

	# `0:a:0?` — the trailing ? makes the audio stream optional, so a silent clip doesn't fail here.
	# It MUST be quoted: `?` is a glob character. bash only survives it unquoted because an
	# unmatched glob passes through literally; zsh errors outright, and a file named `0:a:00` in
	# the working directory would break it under bash too.
	if ! ffmpeg -y -i "$file" -map 0:v:0 -map "0:a:0?" -c copy \
		-color_primaries bt709 -color_trc bt709 -colorspace bt709 \
		"$@" "$tmp" -v error; then
		echo "RETAG FAILED (ffmpeg error) for $file — left as-is, untagged" >&2
		rm -f "$tmp"
		return 1
	fi

	if [ -s "$tmp" ]; then
		mv "$tmp" "$file"
		verify_bt709 "$file"
	else
		echo "RETAG FAILED (empty output) for $file — left as-is, untagged" >&2
		rm -f "$tmp"
		return 1
	fi
}

# Fails loudly before a multi-GB encode starts rather than filling the disk mid-batch.
check_disk_space() {
	local dir="$1"
	local need_gb="$2"
	local avail_gb
	avail_gb=$(($(df -k "$dir" | tail -1 | awk '{print $4}') / 1024 / 1024))
	if [ "$avail_gb" -lt "$need_gb" ]; then
		echo "LOW DISK SPACE: ${avail_gb}GB available in $dir, wanted ${need_gb}GB+" >&2
		return 1
	fi
	echo "disk OK: ${avail_gb}GB available in $dir"
}

# This shoot is MIXED ORIENTATION: of 19 clips, 11 have no rotation matrix (they stay landscape
# 3840x2160), 7 are -90 and IMG_0609 alone is +90 (both of those present as 2160x3840 portrait).
# A vertical delivery script handed a landscape master will happily scale 3840x2160 into
# 1080x1920 — no error, no warning, just a badly squashed file that looks "done". That is the
# dangerous failure in a batch run, so refuse it here instead.
# There is deliberately NO rotation logic in this pipeline — orientation is an ingest concern and
# the source is trusted. This guard exists for one thing only: a genuinely landscape clip reaching
# a vertical deliverable gets silently squashed into 1080x1920, and silent is the problem.
#
# So it decodes one frame and measures it, rather than reasoning about display matrices. ffmpeg
# autorotates on decode, so this reflects what a viewer sees, and it does not care whether the
# source was corrected by re-encoding or by fixing the matrix in Preview.
# --- the look -----------------------------------------------------------------
# One source for every look value: look.json at the repo root. Nothing else may hardcode one.
# Before this existed, `SAT=1.27` was written out in two scripts and had already started to drift
# in the obvious way — two copies, one edited.
look() {  # look <jq-path> [fallback]
	local key="$1" fallback="${2:-}" v
	v=$(jq -r "$key // empty" "$LOOK_FILE" 2>/dev/null) || v=""
	if [ -z "$v" ]; then
		[ -n "$fallback" ] || { echo "look.json: missing $key and no fallback" >&2; return 1; }
		v="$fallback"
	fi
	printf '%s\n' "$v"
}

# The shipped tone LUT is GENERATED from look.json's tone block. Regenerate whenever look.json is
# newer, so the .cube can never silently disagree with the numbers that claim to describe it —
# which is the same failure class as the Bench drifting from the renderer, one layer down.
ensure_tone_lut() {
	# Two lines, not one: bash expands the whole command line BEFORE `local` performs its
	# assignments, so `local a="$1" b="$a"` sees an unset $a — and under `set -u` that aborts.
	local root="$1"
	local cube="$root/luts/tone/shipped.cube"
	if [ -f "$cube" ] && [ "$cube" -nt "$LOOK_FILE" ]; then return 0; fi
	echo "look.json is newer than shipped.cube — regenerating the tone curve"
	"$root/scripts/make-tone-lut.py" "$cube" \
		--gamma    "$(look .tone.gamma)"    --pivot  "$(look .tone.pivot)" \
		--contrast "$(look .tone.contrast)" --toe    "$(look .tone.toe)" \
		--shoulder "$(look .tone.shoulder)" --black  "$(look .tone.black)" >/dev/null
}

resolve_work_dir() {
	local root="$1" w=""
	if [ -n "${GRADE_WORK_DIR:-}" ]; then
		w="$GRADE_WORK_DIR"
	elif [ -f "$root/.workdir" ]; then
		w=$(sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' "$root/.workdir" | head -1)
		case "$w" in "~"*) w="$HOME${w#\~}";; esac
	fi
	[ -n "$w" ] || w="$root"
	if [ ! -d "$w" ]; then
		echo "work directory does not exist: $w" >&2
		echo "  set GRADE_WORK_DIR, or put the path in $root/.workdir" >&2
		return 1
	fi
	printf '%s\n' "$w"
}

# Reads one dimension field on its own. ffprobe appends a TRAILING COMMA on this camera's csv
# output (`3840,2160,`), so splitting a combined string yields an empty height and any numeric
# comparison fails open. Query fields individually and validate.
video_dim() {  # video_dim <file> <width|height>
	ffprobe -v error -select_streams v:0 -show_entries "stream=$2" \
		-of default=nw=1:nk=1 "$1" 2>/dev/null | grep -E '^[0-9]+$' | head -1
}

require_portrait() {
	local file="$1" tmp w h
	tmp="$(mktemp -t portrait).png"
	if ! ffmpeg -v error -y -i "$file" -frames:v 1 "$tmp" 2>/dev/null; then
		rm -f "$tmp"; echo "could not decode a frame from $file" >&2; return 1
	fi
	w=$(ffprobe -v error -show_entries stream=width -of default=nw=1:nk=1 "$tmp" | head -1)
	h=$(ffprobe -v error -show_entries stream=height -of default=nw=1:nk=1 "$tmp" | head -1)
	rm -f "$tmp"
	if [ "$h" -le "$w" ]; then
		echo "REFUSING: $file decodes as ${w}x${h}, not portrait." >&2
		echo "  Vertical delivery would squash it. Fix the source orientation, then retry." >&2
		return 1
	fi
}

require_nonempty() {
	local file="$1"
	local label="$2"
	if [ ! -s "$file" ]; then
		echo "$label FAILED — $file missing or empty" >&2
		return 1
	fi
}
