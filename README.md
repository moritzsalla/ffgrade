# ffgrade

**Apple Log → graded Rec.709 in one ffmpeg pass.** 10-bit preserved to delivery, tone curve applied
to luma only, LUTs generated rather than guessed. No NLE.

iPhone ProRes/Log holds far more than a phone edit gets out of it — roughly 3.6 stops of highlight
headroom above diffuse white, 10-bit 4:2:2, and no baked-in HDR tone mapping or sharpening. The
usual way to reach that is DaVinci Resolve Studio at $295 (the free edition dropped Python
scripting in 21.1). This gets there with ffmpeg and a browser.

```
./scripts/grade.sh ~/Movies/my-shoot        # folder in, finals out
```

![The Grade Bench](docs/grade-bench.png)

*The Grade Bench: set the look by eye at interactive speed, with the calibration references reading
live beside the sliders. Its curve maths is a port of the renderer's, and a test asserts they stay
in step — if the preview stops predicting the render, CI says so rather than the footage.*

## What it does that most ffmpeg grading scripts don't

- **Keeps 10 bits all the way to delivery.** `eq` silently negotiates an 8-bit pixel format, which
  no warning tells you about; it is banned here and the alternatives are documented.
- **Applies the tone curve to luma only.** A per-channel contrast curve crushes a saturated
  colour's two low channels harder than its high one, which is what turns traffic signage neon.
  `mergeplanes` keeps chroma untouched.
- **Dithers the 10→8 bit reduction.** `format=yuv420p` and `-sws_dither ed` are byte-identical —
  i.e. no dithering at all. Only `zscale` actually does it.
- **Generates its LUTs.** The tone curve comes from `look.json` via a generator, so the `.cube` can
  never disagree with the numbers that claim to describe it. The free film-emulation LUTs are all
  13³ grids that supply colour character and almost no contrast — the tone stage exists because of
  that, not despite it.
- **Grain that survives Instagram.** Per-pixel grain does not: re-encoded at ~4 Mbps the compressor
  smears it into blobs. Clustered grain keeps its structure and encodes ~22% cheaper.

Every one of those is a measurement in `docs/PIPELINE.md`, alongside the things that were tried and
lost.

Deliverables per clip: **Reels/Stories** (9:16, 1080×1920) and **Feed** (4:5, 1080×1350).

The reference footage throughout this documentation is a 19-clip set shot on an iPhone 15 Pro in
the Final Cut Camera app: ProRes 422 HQ, Apple Log, 4K24, locked white balance and focus.

## Why it's built this way

**Shoot as raw as the phone allows, decide the look later.** ProRes 422 HQ / Apple Log, 4K24,
locked white balance and focus. Log footage looks flat and wrong straight out of the camera — that
is the point: it preserves range to grade with instead of baking in Apple's decisions. An
"unedited" iPhone photo is in fact heavily processed (HDR tone mapping, local contrast, saturation,
sharpening); log gives that processing back to us as a choice.

**The work is tone, not colour.** The single most useful finding here. Apple's own Log→Rec.709 LUT
is already colorimetrically accurate — verified against standardised colours physically in frame,
it lands the traffic-blue sign at B/G 1.99 against a 1.98 spec with nothing applied. The footage
looked flat because it sat ~25% too bright with nothing reaching black, and because a stills film
LUT supplies a print emulation, not a cinema tone response. Chasing colour was wasted effort;
shaping tone was the whole fix.

**Tuning aid: calibrate against colours that are legally defined.** Not the point of the tool,
but the thing that settled most of its arguments.

| | |
|---|---|
| ![Traffic signs](docs/reference-traffic-signs.png) | ![Licence plate](docs/reference-licence-plate.png) |
| Dutch traffic signage — RAL 3020 red, RAL 5017 blue | Dutch plate yellow — RAL 1021 |

Rather than grade purely by eye, the
frame is sampled at objects with published specs — Dutch licence-plate yellow (RAL 1021), traffic
red (RAL 3020), traffic blue (RAL 5017) — plus a neutral surface. That converts "does this look
right" into a measurement. It catches the failure mode where a contrast curve quietly turns signage
neon, and it caught several confident-but-wrong judgements made by eye during development.

![Grade ladder](docs/grade-ladder-variants.png)

*A strength ladder: the same frame at four points along one parameter. Comparisons like this are
how every decision in `docs/PIPELINE.md` was settled — the numbers beside them, not instead.*

**But accuracy is not a grade.** The references say where you are, not where to go. The shipped
look deliberately sits off-spec (saturation 1.27 puts the blue at 2.39). That is intent, not error.
The tooling exists to make the departure _visible and chosen_, not to prevent it.

## How the work splits

Measurement and rendering are automated; the look is a human call. The two meet in
**`bench/`** — a browser tool (published as an Artifact) with real-time sliders over the
actual frame, live readouts of every RAL reference beside them, and a button that sends the chosen
settings straight back to Claude. One grading session replaces a round trip per adjustment, and the numbers transfer to the pipeline verbatim because the tool's curve maths is a port of
`make-tone-lut.py`.

## Layout

Source and inputs at the top level; `dist/` is only ever things a render wrote, and is
reconstructible from `src/` plus the scripts.

**The footage does not have to live here.** A shoot is tens of gigabytes, which has no business in
a synced folder or near a git remote, so `src/` and `dist/` resolve through a work directory:
`$GRADE_WORK_DIR`, else a one-line `.workdir` file at the repo root (gitignored), else the repo
itself. Clone it with nothing configured and it works self-contained; point `.workdir` at a media
volume and the same scripts run unchanged. Everything else — code, docs, LUTs — stays in the repo.

```
src/            Original camera files. NEVER modified or moved.
scripts/        The pipeline itself. Stage scripts + LUT generators. Start at lib.sh.
bench/          The Grade Bench: source of truth for the browser tool (published copy is an
                Artifact). Named for the tool, not the folder — in this trade a grader is a person.
luts/
  apple/          Apple's official Log→Rec709 and Log→Lin LUTs (free Apple ID download).
  looks/          Film-emulation look LUTs. See SOURCE.txt for provenance.
  tone/           shipped.cube — the one tone curve that ships.
    variants/     The 14 candidates the search passed through. Kept as evidence, not in use.
  filmic/         Output of the rejected log→linear→filmic route. See ADR-0002.
dist/            Generated. Safe to delete and re-render; nothing here is a source.
  01-baseline/    Log→Rec.709, rotation fixed, correct tags. No creative decisions.
  02-graded/      + look + tone + sat. The ProRes master; re-export from here, never from an MP4.
  03-final/       Delivery MP4s, named for their deliverable.
  proofs/         Cheap fast renders for sign-off before committing to a slow full render.
  stab/           Camera-motion transforms (.trf), per clip. Motion-only, so they survive a re-grade.
docs/
  PIPELINE.md       Every finding, measurement, dead end and mistake. The real documentation.
  BATCH_RUNBOOK.md  Per-clip procedure, how to run a grading session, what must NOT be batched.
  SHOOTING_NOTES.md Capture-side lessons — what to change on the next shoot, before the grade.
  HOW_TO_SHOOT.md   The camera settings, in plain language for whoever is holding the phone.
  BACKLOG.md        Everything raised and not finished, and what was declined and why.
  adr/              The decisions that would otherwise get "fixed" by a later reader.
tests/            bats suite over the safety layer. Run via scripts/check.sh.
CONTEXT.md        The project's own vocabulary, one term per concept, and the words ruled out.
```

## Before touching anything

- **Read `docs/PIPELINE.md`.** It records not just what works but what was tried and failed, with
  measurements — including two bugs in the safety scripts themselves, an ffmpeg filter that
  silently drops the pipeline to 8-bit, and a "fix" that made the image measurably worse.
- **Read `CONTEXT.md`** if you are going to write anything down. Several of these words mean two
  things in ordinary speech and exactly one here — *look* is not *tone* is not *grade*, *spec* is
  not *target*, and a *baseline* is not a *master*. Some file and variable names still carry the
  ruled-out word; CONTEXT.md says which.
- **Run stages through `scripts/`,** not by hand. They carry exit-code checks, tag
  verification, disk-space checks and an orientation guard, each of which exists because its
  absence already cost something.
- **`src/` is read-only.** Every output goes to `dist/`.
- **Run `./scripts/check.sh` after touching anything in `scripts/`.** It runs shellcheck and the
  bats suite. Both, because neither catches what the other does: shellcheck reported ZERO issues
  in scripts that contained two shipped, load-bearing bugs, while bats found both by running the
  code on the real interpreter (macOS ships bash 3.2, whose empty-array handling under `set -u`
  differs from every modern bash).

## Tests

`tests/lib.bats` — 17 tests over the safety layer. Every one exists because the guard it covers
either already failed in production or shipped broken and went unnoticed.

Two things about this suite worth knowing before extending it:

- **It has been mutation-tested.** Each guard was deliberately broken to confirm the matching test
  goes red. That found two tests that passed against a *removed* guard — pure theatre — both
  because a synthetic fixture could not reproduce the condition (ffprobe repeats the video stream
  only for files with the camera's stream-group structure; a generated fixture prints one line).
  Those tests now use real footage from `src/` and skip if it is absent.
- **One escaping mutation is correct, not a gap.** Removing `safe_retag`'s empty-output check
  changes nothing observable — `mv` fails on its own and `set -e` aborts. The test there asserts
  the property that matters (the original is never destroyed) rather than a message, and says so.

Install: shellcheck as a prebuilt binary into `~/.local/bin`; bats via
`git clone bats-core && ./install.sh ~/.local`. Neither via Homebrew, per this machine's rules.
