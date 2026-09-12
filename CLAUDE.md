# CLAUDE.md

Guidance for Claude Code working in this repo. `README.md` is the human orientation; this file
carries what an agent needs on top of it — the traps, and where the source of truth lives.

Read `docs/PIPELINE.md` before changing the render chain, and `CONTEXT.md` before writing anything
down. Several words here mean one specific thing: *look* is not *tone* is not *grade*, a *spec* is
what you measure against and depart from deliberately, and a *baseline* is not a *master*.

## Run this before trusting any change

```sh
./scripts/check.sh        # shellcheck, curve parity, 17 bats tests
```

**shellcheck and bats are not substitutes for each other.** shellcheck reported ZERO issues in
scripts that contained two shipped, load-bearing bugs. bats found both, because it runs the code on
the real interpreter — macOS ships **bash 3.2**, whose handling of empty arrays under `set -u`
differs from every modern bash. Run both.

## Filter findings that look arbitrary until you know why

Each of these is measured; the numbers are in `docs/PIPELINE.md`. They are the reason the render
chain looks the way it does, and each one was a silent failure — no error, just wrong output.

- **`eq` silently negotiates an 8-bit pixel format.** ffmpeg auto-inserts a scaler
  (`yuv422p10le → yuv422p`) with no warning, so any chain using it has quietly stopped being a
  10-bit pipeline. Banned. Verify any new filter with `-v debug | grep "picking yuv"`.
- **`colorlevels` produces a flat frame** on this input. Not investigated; `curves` works.
- **A per-channel contrast curve wrecks saturated colour.** It crushes the two low channels harder
  than the high one, which turns traffic signage neon. The tone curve is applied to the **luma
  plane only** via `mergeplanes=0x001112`, chroma merged back untouched. `format=yuv444p10le` is
  required on both branches or mergeplanes fails with a bare "Invalid argument".
- **`format=yuv420p` and `-sws_dither ed` are byte-identical** — i.e. neither dithers at all. Only
  `zscale` does the 10→8 bit reduction properly.
- **`curves` interpolates with a cubic spline, not straight lines.** More than ~3 control points
  with uneven slope overshoots past identity somewhere you didn't intend. A 5-point shadow
  correction once made the image *brighter* than the uncorrected version. Measure the result;
  don't trust the control points.
- **Per-pixel grain does not survive delivery.** Re-encoded at ~4 Mbps the compressor smears it
  into blobs (lag-1 autocorrelation 0.00 → 0.39). Grain generated at half resolution and blended
  keeps its structure *and* encodes ~22% cheaper. Apply it **after** the sharpener; before it, the
  sharpener rings the grain and weakens it.
- **An untagged branch poisons the whole filter graph.** ffmpeg negotiates formats across the
  entire graph, so a `lavfi` source with no colour metadata propagates "unknown" backwards and a
  `zscale` several filters upstream fails with `code 3074: no path between colorspaces`. Tag
  synthesised branches with `setparams`. `mergeplanes` output is untagged the same way.
- **`blend` needs `shortest=1`.** `-shortest` is not a substitute with `filter_complex`: an
  infinite `lavfi` source will drive the encode forever and the output grows without bound.
- **Encoders don't reliably stamp colour tags.** Both `prores_ks` and `libx264` ignored
  `-color_primaries`/`-color_trc`/`-colorspace` here. A wrongly tagged file is double-transformed
  by any player that trusts the tag — this is what "bleached out" was. Always verify after an
  encode and fix with a `-c copy` remux.

## ffprobe misreports this camera's files in three ways

All silent, all cost real time. The files carry a `[STREAM_GROUP]` structure that ordinary idioms
don't expect.

1. **The video stream prints twice**, plus a blank line. Comparing that to one expected value always
   fails — this is how `verify_bt709` shipped in a state where it could never pass.
2. **`-select_streams a:0` returns nothing** despite audio being present. A silence check written
   the obvious way reports every clip silent. `-map 0:a:0?` for ffmpeg is unaffected — different
   code path.
3. **A trailing comma** on csv output (`3840,2160,`), so `${dims##*,}` is empty and a numeric
   comparison fails open. This is how the portrait guard shipped accepting landscape clips.

Query fields individually with `-of default=nw=1:nk=1` and validate with a regex. Never trust a
single-line ffprobe answer without checking what it actually printed.

## Testing rules

- **Mutation-test anything you add.** Break the guard, confirm the test goes red. Two tests here
  passed against a *removed* guard before this was done.
- **Synthetic fixtures cannot reproduce this camera's quirks.** A generated ProRes file prints one
  clean ffprobe line; a real clip prints three with a trailing comma. Tests covering those
  behaviours must use real footage from `src/` and skip when it is absent.
- A test that cannot fail is worse than no test — it reads as coverage.

## Things that are settled, don't re-litigate

- **Tone, not colour.** Apple's CST is already colorimetrically accurate (traffic blue at B/G 1.99
  against a 1.98 spec, nothing applied). Hours went into "fixing" colour that was correct. The
  flatness was tone: ~25% too bright with nothing reaching black.
- **The shipped look is deliberately off-spec** (saturation 1.27 puts that blue at 2.39). That is
  the grade, not an error. Do not "correct" it toward the reference.
- **Rotation is an ingest concern.** No rotation logic in the pipeline; the source is trusted. The
  one guard decodes a frame and measures it, refusing non-portrait rather than squashing it.
- **The scene-linear filmic route was tried and lost on colour.** Kept in `luts/filmic/` with its
  measurements. See `docs/adr/0002_KEEP_APPLES_CST.md`.
- **Look values live in `look.json`,** never hardcoded in a script. `shipped.cube` regenerates from
  it automatically when it goes stale.

## Style

Tabs in shell scripts. Comments explain *why* — a rejected alternative, a measurement, a trap —
never *what*. Most of the comments in `scripts/` exist to stop a future reader "simplifying" away
something that was expensive to learn.
