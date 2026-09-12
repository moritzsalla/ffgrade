# ffgrade

**Apple Log → graded Rec.709 in one ffmpeg pass.** 10-bit preserved to delivery, tone curve applied
to luma only, LUTs generated rather than guessed. No NLE.

A personal tool. I shoot on an iPhone in ProRes / Apple Log for Instagram, and wanted the footage
to look like it was graded rather than like phone video. The obvious route is DaVinci Resolve
Studio — $295, because the free edition dropped Python scripting in 21.1 and I wanted this
automated, not clicked. That is a lot for something I was mostly curious about, so I found out how
far ffmpeg alone would get.

Quite far, it turns out. Log holds roughly 3.6 stops of highlight headroom above diffuse white,
10-bit 4:2:2, and none of the HDR tone mapping or sharpening a normal phone capture bakes in.
Getting that out of it is a tone problem, and tone is something ffmpeg can do properly.

```
./scripts/grade.sh ~/Movies/my-shoot        # folder in, finals out
```

![The Grade Bench](docs/grade-bench.png)

*The Grade Bench: set the look by eye at interactive speed, with the calibration references reading
live beside the sliders. Its curve maths is a port of the renderer's, and a test asserts they stay
in step — if the preview stops predicting the render, something says so before the footage does.*

## Scope, honestly

Built for my footage, my machine, my deliverables. macOS on Intel, bash 3.2, ffmpeg from
`~/.local/bin`. Output is hardcoded to Instagram's two shapes. The look is one I like; yours will
differ, which is what `look.json` and the Bench are for.

It is not a product and there is no roadmap. It is shared because the measurements in
`docs/PIPELINE.md` were expensive to get and might save someone else the same afternoon — including
the several places I was confidently wrong and only the numbers caught it.

## Things I got wrong, and what the measurements said

The findings that cost the most time, each reproducible from `docs/PIPELINE.md`:

- **`eq` silently negotiates an 8-bit pixel format.** No warning. Any chain using it has quietly
  stopped being a 10-bit pipeline. Banned here; alternatives documented.
- **A per-channel contrast curve wrecks saturated colour.** It crushes the two low channels harder
  than the high one, which is what turns traffic signage neon. `mergeplanes` applies the curve to
  luma only and leaves chroma alone.
- **`format=yuv420p` and `-sws_dither ed` are byte-identical** — i.e. neither dithers. Only
  `zscale` actually does the 10→8 bit reduction properly.
- **Per-pixel grain does not survive delivery.** Re-encoded at ~4 Mbps the compressor smears it
  into blobs. Grain generated at half resolution keeps its structure *and* encodes ~22% cheaper.
- **The free film-emulation LUTs are all 13³ grids** supplying colour character and almost no
  contrast. The tone stage exists because of that, not despite it.
- **I spent hours "fixing" colour that was already correct.** Apple's CST lands the standardised
  traffic blue at B/G 1.99 against a 1.98 spec with nothing applied. The image looked flat because
  it sat ~25% too bright with nothing reaching black. Tone, not colour.

Deliverables per clip: **Reels/Stories** (9:16, 1080×1920) and **Feed** (4:5, 1080×1350).

Reference footage throughout the docs is a 19-clip set shot on an iPhone 15 Pro in the Final Cut
Camera app: ProRes 422 HQ, Apple Log, 4K24, locked white balance and focus.

## How it works

**Shoot as raw as the phone allows, decide the look later.** ProRes 422 HQ / Apple Log, 4K24,
locked white balance and focus. Log looks flat and wrong straight out of the camera — that is the
point: it keeps the range instead of spending it on Apple's decisions. An "unedited" iPhone photo
is in fact heavily processed; Log hands that processing back as a choice.

**Then fix tone, and mostly leave colour alone** (see above — this took me a while to accept).

**Calibrating against colours that are legally defined** is how the arguments got settled. Not the
point of the tool, but the reason I trust its numbers.

| | |
|---|---|
| ![Traffic signs](docs/reference-traffic-signs.png) | ![Licence plate](docs/reference-licence-plate.png) |
| Dutch traffic signage — RAL 3020 red, RAL 5017 blue | Dutch plate yellow — RAL 1021 |

The frame gets sampled at objects with published specs — plate yellow (RAL 1021), traffic red
(RAL 3020), traffic blue (RAL 5017) — plus any neutral surface. That turns "does this look right"
into a number, which is what caught the contrast curve quietly turning signage neon, and several
judgements I'd made by eye and got wrong.

![Grade ladder](docs/grade-ladder-variants.png)

*A strength ladder: one frame at four points along a single parameter. Every decision in
`docs/PIPELINE.md` was settled like this — the comparison and the measurement together.*

**Accuracy is not a grade, though.** The references tell you where you are, not where to go. The
look I ship is deliberately off-spec — saturation 1.27 puts the blue at 2.39 against a 1.98 spec.
That is the grade, not an error. The point of the readouts is to make the departure visible and
chosen, not to stop it.

## How the work splits

Measurement and rendering are automated; the look is mine to decide. The two meet in
**`bench/`** — a browser tool (published as an Artifact) with real-time sliders over the
actual frame, live readouts of every RAL reference beside them, and a button that sends the chosen
settings straight back to Claude. One grading session replaces a round trip per adjustment, and the numbers transfer to the pipeline verbatim because the tool's curve maths is a port of
`make-tone-lut.py`.

## Layout

Source and inputs at the top level; `dist/` is only ever things a render wrote, and is
reconstructible from `src/` plus the scripts.

**Footage goes in `src/`, output comes out of `dist/`.** No configuration, no paths to edit —
clone, drop clips in, run. Both are gitignored, along with every video extension, so a shoot can
sit in the working tree without any risk of being committed.

If you would rather keep footage on another volume, `src/` and `dist/` resolve through
`$GRADE_WORK_DIR` or a one-line `.workdir` file at the repo root. Neither is needed by default.

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
