# Running the pipeline on a new clip

The mechanical steps (LUT application, tag fixing, encoding) are scripted in `scripts/`.
The judgment calls below are NOT scripted — they can't be safely automated in a blind loop and
need a preview frame actually looked at, per clip. Rotation, white balance and the Feed crop each
have a per-clip answer, and each has already been got wrong by assuming the previous clip's
(see docs/PIPELINE.md, "Mistakes made", and "Mixed orientation" below).

## Per-clip procedure

1. **Baseline**: `./scripts/01-baseline.sh IMG_XXXX`
2. **Check rotation** — pull a preview frame from the baseline output and look at it. Trust
   ffmpeg's autorotate by default; if the result is upside down or sideways anyway (happened once,
   on IMG_0609), re-run step 1 with `180` as the second argument. Don't assume the same fix
   applies to the next clip — check each one.
3. **Check white balance** — sample a real neutral reference in the frame (road, sidewalk, an
   overcast sky — not a colored surface) and confirm it reads close to neutral (R≈G≈B). WB was
   locked at capture, so this should hold across clips, but "should" isn't "confirmed" — spot
   check, don't skip because it's tedious.
4. **Grade**: `./scripts/02-grade.sh IMG_XXXX`
5. **Generate fast proofs** (cheap preset, not the final encode) for both aspect ratios and get
   sign-off before committing to the slow final render — see the proof-generation pattern used
   for IMG_0609 (fast preset, higher CRF, same filter chain as the real export).
6. **Pick the Feed crop offset** — pull 1-2 crop candidates from the graded master at different
   vertical offsets, look at them, pick one (or ask). Pass it as the second argument to
   `03-final-feed.sh`. Don't reuse IMG_0609's offset (750) blindly — composition differs per clip.
7. **On sign-off, run the real finals**:
   - `./scripts/03-final-reels.sh IMG_XXXX`
   - `./scripts/03-final-feed.sh IMG_XXXX <crop_y>`
8. **Clean up**: once both finals are confirmed good, delete that clip's
   `dist/01-baseline/<clip>_baseline.mov` and `dist/02-graded/<clip>_graded.mov` — see
   docs/PIPELINE.md's disk space policy. Keep only `dist/03-final/*` for that clip going forward.

## Running a grading session (the Grade Bench)

The grade is decided by eye in the Grade Bench — `bench/`, a browser tool published as an
Artifact. (The folder is named `grader`, the tool calls itself the Grade Bench; **Bench** is the
term — see `CONTEXT.md`. In this trade a grader is a person.) It exists because the alternative
(render a proof → watch it → describe the problem in words → Claude reinterprets → render again)
costs a round trip per adjustment and loses information at both the "describe" and "reinterpret"
steps.

**To grade a clip:**

1. Extract a frame from the **baseline, with the look LUT applied but no tone stage** — that is
   exactly the input the tone LUT sees, so the preview matches the render. (The Bench's own hint
   says only "post-CST, pre-tone"; post-*look* is the part it leaves out, and a frame without the
   look in it will mispredict every reading.)
   ```bash
   ffmpeg -y -i dist/01-baseline/IMG_XXXX_baseline.mov -ss 4 -frames:v 1 \
     -vf "lut3d=file='luts/looks/kodak_portra_400_nc.cube':interp=tetrahedral,scale=810:-1" \
     -q:v 3 frame.jpg
   ```
2. Open the Artifact, drag the frame in (or use "Open frame…").
3. Place the reference samplers: click a reference name in the panel, then click that object in the
   picture. They are **not** at fixed coordinates across shoots — a plate or sign is wherever it is.
4. Grade with the sliders. The readouts show each reference against its RAL spec live.
5. Add a note if the numbers don't capture it, and hit **Send grade**.

Claude reads the result from the artifact's db (`grades` collection) — each entry carries the
parameters, the measured readings, the note and the clip name.

**The tool's curve maths is a port of `make-tone-lut.py`** and it applies the curve to luma only,
mirroring `mergeplanes=0x001112`. Keep them in step: if one changes, change the other, or the
preview stops predicting the render.

**Republishing:** the source of truth is `bench/index.html`. The Artifact tool will only
publish from the working directory or the session scratchpad, so copy it there first and publish
from the copy; pass the artifact's existing URL to update in place rather than creating a second
one.

**Two fidelity caveats to keep in mind while grading:** the preview frame is an 8-bit JPEG, so very
fine gradients look slightly rougher than the 10-bit render; and objects in shade read darker and
less saturated than their RAL spec, so the references are hue and ratio guides, not exposure ones.

## Mixed orientation — three classes, read off the file

This shoot is not uniformly tagged, but the classes are machine-readable, so this is three checks
rather than nineteen eyeball passes. `rotation_class` in `scripts/lib.sh` prints the right
`ROTATE_FIX` for any clip:

| Rotation matrix | ROTATE_FIX | Clips | What is going on |
|---|---|---|---|
| −90° | `none` | IMG_0619–0625 (7) | autorotate already correct |
| +90° | `180` | IMG_0609 (1) | autorotate lands it upside down |
| **absent** | `cw` | IMG_0607, 0608, 0610–0618 (11) | portrait content stored as landscape with no flag |

**The third class was misread for a long time as "landscape footage".** With no matrix, ffmpeg has
nothing to rotate by, so the frame stays sideways — and a sideways portrait frame looks exactly
like a landscape composition in a file listing. It was treated as a framing problem needing a crop
decision, and it blocked the rest of the shoot. It is not: the content is portrait and the flag is
simply missing. `transpose=1` fixes it, nothing is discarded, and no creative call is needed.

The lesson is the cheap one: render a frame before reasoning about geometry. One `ffmpeg` call
would have settled it at the start.

The `require_portrait` guard in the export stages still earns its place — it catches a genuinely
landscape master reaching a vertical deliverable, which would otherwise be squashed silently.

## What's safe to batch, what isn't

Safe to loop unattended: nothing yet, actually — even step 1 (baseline) needs its rotation
checked before step 4 can be trusted. This pipeline is "scripted mechanics, per-clip human gate,"
not "point at 18 files and walk away."
