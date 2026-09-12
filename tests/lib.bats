#!/usr/bin/env bats
# Tests for scripts/lib.sh — the safety layer.
#
# WHY THIS FILE EXISTS. Every helper in lib.sh was written in response to a real incident, and
# then two of them shipped BROKEN and stayed broken because nothing ever exercised them:
#
#   - `safe_retag` died on every call with "unbound variable" (bash 3.2 + `set -u` + an empty
#     array), silently skipping the retag it exists to perform and leaving masters mistagged.
#   - `verify_bt709` could never pass on ANY file, because ffprobe prints these files' video
#     stream twice and it compared that against a single expected line.
#
# Neither is caught by shellcheck — verified: it reports nothing on the empty-array pattern while
# bash 3.2 fails on it immediately. Only running the code finds them.
#
# So the bar for every test here: delete the guard it covers and the test must go red. A test that
# cannot fail is worse than no test, because it reads as coverage.
#
# Run:  bats tests/

setup_file() {
	command -v ffmpeg >/dev/null || skip "ffmpeg not installed"
	export FIXTURES="$BATS_FILE_TMPDIR/fixtures"
	mkdir -p "$FIXTURES"

	# Tiny synthetic clips — one frame each, so the suite stays fast.
	#
	# NOTE ON HOW THESE ARE BUILT. Passing -color_primaries/-color_trc/-colorspace to prores_ks
	# does NOT produce a correctly tagged file: it writes "bt709,unknown,unknown". That is the
	# very bug the pipeline's retag pass exists for, and the first version of this suite tripped
	# over it — a fixture named "correctly tagged" that wasn't, failing a test of a function that
	# was working fine. So the tagged fixtures are built the way the pipeline builds real output:
	# encode first, then apply tags in a separate `-c copy` remux.
	_mk() {  # _mk <w> <h> <primaries> <trc> <matrix> <out>
		local w=$1 h=$2 prim=$3 trc=$4 mtx=$5 out=$6
		ffmpeg -y -f lavfi -i "color=c=gray:s=${w}x${h}:d=0.1:r=24" \
			-frames:v 1 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le \
			"$out.raw.mov" -v error
		ffmpeg -y -i "$out.raw.mov" -map 0:v:0 -c copy \
			-color_primaries "$prim" -color_trc "$trc" -colorspace "$mtx" \
			"$out" -v error
		rm -f "$out.raw.mov"
	}
	_mk 64 128 bt709 bt709 bt709 "$FIXTURES/portrait_tagged.mov"
	_mk 128 64 bt709 bt709 bt709 "$FIXTURES/landscape_tagged.mov"
	# Deliberately MIStagged as bt2020 — the "bleached out" state this pipeline exists to prevent.
	_mk 64 128 bt2020 bt709 bt2020nc "$FIXTURES/portrait_bt2020.mov"
}

setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../scripts"
	# lib.sh sets -euo pipefail; that is fine to inherit inside a bats test body.
	source "$SCRIPTS/lib.sh"
}

# --- require_nonempty --------------------------------------------------------

@test "require_nonempty accepts a file with content" {
	echo data > "$BATS_TEST_TMPDIR/f"
	run require_nonempty "$BATS_TEST_TMPDIR/f" "test"
	[ "$status" -eq 0 ]
}

@test "require_nonempty rejects a zero-byte file" {
	: > "$BATS_TEST_TMPDIR/empty"
	run require_nonempty "$BATS_TEST_TMPDIR/empty" "test"
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing or empty"* ]]
}

@test "require_nonempty rejects a missing file" {
	run require_nonempty "$BATS_TEST_TMPDIR/nope" "test"
	[ "$status" -ne 0 ]
}

# --- require_portrait --------------------------------------------------------
# The guard that stops a landscape master being silently squashed into 1080x1920.
# 11 of this shoot's 19 clips are landscape, so this is not a hypothetical.

@test "require_portrait accepts a portrait clip" {
	run require_portrait "$FIXTURES/portrait_tagged.mov"
	[ "$status" -eq 0 ]
}

@test "require_portrait refuses a landscape clip" {
	run require_portrait "$FIXTURES/landscape_tagged.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"REFUSING"* ]]
	[[ "$output" == *"landscape"* ]]
}

@test "require_portrait reports the real dimensions, not a guess" {
	run require_portrait "$FIXTURES/landscape_tagged.mov"
	[[ "$output" == *"128x64"* ]]
}

# --- verify_bt709 ------------------------------------------------------------
# Shipped broken: compared ffprobe's output (which prints the stream TWICE for these files,
# plus a blank line) against one expected line, so it failed on correctly tagged files.

@test "verify_bt709 PASSES on a correctly tagged file" {
	run verify_bt709 "$FIXTURES/portrait_tagged.mov"
	[ "$status" -eq 0 ]
}

@test "verify_bt709 FAILS on a bt2020-tagged file" {
	run verify_bt709 "$FIXTURES/portrait_bt2020.mov"
	[ "$status" -ne 0 ]
	[[ "$output" == *"TAG CHECK FAILED"* ]]
}

@test "probe_tags dedups ffprobe's repeated stream on a REAL camera file" {
	# This MUST use real footage. ffprobe repeats the video stream (and adds a blank line) only
	# for files with the camera's [STREAM_GROUP] structure — a synthetic lavfi/prores fixture
	# prints a single line, so it cannot exercise the dedup at all. Verified by mutation: with
	# the dedup removed, a synthetic-fixture version of this test still passed. Real file: 3
	# lines. Synthetic: 1.
	# Footage lives under the work dir, which is NOT the repo when media is kept outside it
	# (see scripts/lib.sh resolve_work_dir). Resolve it the same way the pipeline does.
	local work real
	work=$(resolve_work_dir "$BATS_TEST_DIRNAME/.." 2>/dev/null) || work="$BATS_TEST_DIRNAME/.."
	real=$(ls "$work"/src/*.mov 2>/dev/null | head -1)
	[ -n "$real" ] && [ -f "$real" ] || skip "no source footage in $work/src"
	# Guard the guard: confirm the raw output really is multi-line, or this test proves nothing.
	local raw
	raw=$(ffprobe -v error -select_streams v:0 \
		-show_entries stream=color_space,color_transfer,color_primaries \
		-of csv=p=0 "$real" | wc -l | tr -d ' ')
	[ "$raw" -gt 1 ] || skip "this clip does not trigger the repeat; test would be vacuous"
	run probe_tags "$real"
	[ "${#lines[@]}" -eq 1 ]
}

@test "verify_bt709 gives a verdict (not a parse artefact) on a REAL camera file" {
	# Footage lives under the work dir, which is NOT the repo when media is kept outside it
	# (see scripts/lib.sh resolve_work_dir). Resolve it the same way the pipeline does.
	local work real
	work=$(resolve_work_dir "$BATS_TEST_DIRNAME/.." 2>/dev/null) || work="$BATS_TEST_DIRNAME/.."
	real=$(ls "$work"/src/*.mov 2>/dev/null | head -1)
	[ -n "$real" ] && [ -f "$real" ] || skip "no source footage in $work/src"
	# Source footage is bt2020-tagged, so this must FAIL — and fail with the tag message, not
	# because the comparison tripped over multi-line output.
	run verify_bt709 "$real"
	[ "$status" -ne 0 ]
	[[ "$output" == *"TAG CHECK FAILED"* ]]
	[[ "$output" == *"bt2020"* ]]
}

# --- safe_retag --------------------------------------------------------------
# Shipped broken on bash 3.2 (macOS): an empty array under `set -u` raised "unbound variable",
# so the retag never ran. shellcheck does not flag this — only executing it does.

@test "safe_retag works with NO extra args (the bash 3.2 empty-array case)" {
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/x.mov"
	run safe_retag "$BATS_TEST_TMPDIR/x.mov"
	[ "$status" -eq 0 ]
	[[ "$output" != *"unbound variable"* ]]
	run probe_tags "$BATS_TEST_TMPDIR/x.mov"
	[ "$output" = "bt709,bt709,bt709" ]
}

@test "safe_retag works WITH extra args" {
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/y.mov"
	run safe_retag "$BATS_TEST_TMPDIR/y.mov" -metadata "comment=test"
	[ "$status" -eq 0 ]
	run probe_tags "$BATS_TEST_TMPDIR/y.mov"
	[ "$output" = "bt709,bt709,bt709" ]
}

@test "safe_retag leaves the original intact when the remux fails" {
	# A text file is not remuxable; the original must survive rather than be replaced by a
	# zero-byte failure. This is the incident that destroyed a finished 170MB render.
	echo "not a video" > "$BATS_TEST_TMPDIR/z.mov"
	before=$(cat "$BATS_TEST_TMPDIR/z.mov")
	run safe_retag "$BATS_TEST_TMPDIR/z.mov"
	[ "$status" -ne 0 ]
	[ "$(cat "$BATS_TEST_TMPDIR/z.mov")" = "$before" ]
	[ ! -f "$BATS_TEST_TMPDIR/z_tagged.mov" ]
}

# --- check_disk_space --------------------------------------------------------

@test "check_disk_space passes when space is plentiful" {
	run check_disk_space "$BATS_TEST_TMPDIR" 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"disk OK"* ]]
}

@test "check_disk_space fails when asking for an absurd amount" {
	run check_disk_space "$BATS_TEST_TMPDIR" 99999999
	[ "$status" -ne 0 ]
	[[ "$output" == *"LOW DISK SPACE"* ]]
}

# --- safe_retag's SECOND guard ------------------------------------------------
# The exit-code check catches a crashing ffmpeg; the `-s` check behind it is for ffmpeg exiting 0
# having written nothing.
#
# HONEST NOTE ON COVERAGE: mutation testing shows removing that `-s` check changes NOTHING
# observable — `mv` then fails on the missing file and `set -e` aborts, so the original survives
# either way. No test can distinguish the two implementations, because there is no behavioural
# difference to detect. The guard is redundant defence-in-depth and the escaping mutation is
# correct, not a gap.
#
# So this test asserts the PROPERTY that matters (the original is never destroyed), not the
# specific message. It would catch a future refactor that dropped `set -e` or reordered the mv.

@test "safe_retag never destroys the original when ffmpeg produces nothing" {
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	printf '#!/bin/bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/ffmpeg"
	chmod +x "$BATS_TEST_TMPDIR/bin/ffmpeg"
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/keep.mov"
	before=$(md5 -q "$BATS_TEST_TMPDIR/keep.mov")
	PATH="$BATS_TEST_TMPDIR/bin:$PATH" run safe_retag "$BATS_TEST_TMPDIR/keep.mov"
	[ "$status" -ne 0 ]
	[ "$(md5 -q "$BATS_TEST_TMPDIR/keep.mov")" = "$before" ]
}

# --- argument quoting ---------------------------------------------------------

@test "safe_retag's -map argument survives a hostile working directory" {
	# `-map 0:a:0?` contains a glob character. Unquoted, bash only survives it because unmatched
	# globs pass through literally — so a file whose name matches would silently change the
	# argument. (zsh errors on it outright, which is how this was found.)
	cd "$BATS_TEST_TMPDIR"
	touch '0:a:00'
	cp "$FIXTURES/portrait_bt2020.mov" "$BATS_TEST_TMPDIR/q.mov"
	run safe_retag "$BATS_TEST_TMPDIR/q.mov"
	[ "$status" -eq 0 ]
	run probe_tags "$BATS_TEST_TMPDIR/q.mov"
	[ "$output" = "bt709,bt709,bt709" ]
}

# --- smoke: the scripts must actually RUN -------------------------------------
# These exist because the rest of this suite once passed in full while FOUR functions were missing
# from lib.sh and every stage script died on the first line with "command not found". shellcheck
# does not run the code, the parity check does not touch lib.sh, and the unit tests only call the
# handful of functions they cover — so nothing noticed the pipeline was completely broken.
#
# A suite that cannot detect "the program does not start" is not a suite.

@test "lib.sh defines every function the stage scripts call" {
	source "$BATS_TEST_DIRNAME/../scripts/lib.sh"
	for fn in probe_tags verify_bt709 safe_retag check_disk_space require_nonempty \
	          require_portrait video_dim resolve_work_dir look ensure_tone_lut; do
		run type -t "$fn"
		[ "$output" = "function" ] || { echo "MISSING: $fn"; false; }
	done
}

@test "every stage script starts and reports usage rather than dying" {
	for s in 01-baseline 02-grade 03-final-reels 03-final-feed 00-stabilise-detect; do
		run "$BATS_TEST_DIRNAME/../scripts/$s.sh" __NO_SUCH_CLIP__
		# It must fail on the MISSING CLIP, not on a broken script.
		[[ "$output" != *"command not found"* ]] || { echo "$s.sh: $output"; false; }
		[[ "$output" != *"unbound variable"* ]]  || { echo "$s.sh: $output"; false; }
		[[ "$output" == *"not found"* ]]         || { echo "$s.sh gave: $output"; false; }
	done
}

@test "grade.sh plans a real clip end to end (dry run)" {
	local work src
	work=$(resolve_work_dir "$BATS_TEST_DIRNAME/.." 2>/dev/null) || work="$BATS_TEST_DIRNAME/.."
	src=$(ls "$work"/src/*.mov 2>/dev/null | head -1)
	[ -n "$src" ] || skip "no source footage"
	DRY=1 run "$BATS_TEST_DIRNAME/../scripts/grade.sh" "$src"
	[ "$status" -eq 0 ]
	[[ "$output" == *"clip(s)"* ]]
	[[ "$output" != *"command not found"* ]]
}
