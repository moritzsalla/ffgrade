# Capture notes — what to do differently next shoot

Written after grading this shoot. Everything here is a decision made at capture time that either
helped or cost something downstream. Camera settings are cheap to change; none of this is fixable
in the grade.

## What worked, keep doing

- **ProRes 422 HQ + Apple Log, 4K24.** The right call. Log carries linear values up to 12× diffuse
  white (~3.6 stops of headroom above white) and this shoot used ~5.4× of it. That headroom is the
  raw material the grade shapes; a standard Rec.709 capture would have thrown it away in-camera.
- **Locked focus.** No hunting mid-shot, nothing to fix.
- **24 fps.** Matches the intended look and Instagram handles it fine.

## Locked white balance — know what it costs

IMG_0609 was shot at 20:02 local, about 20 minutes before sunset: golden hour. The footage does
not look like golden hour, and that is the locked WB working exactly as designed — it compensates
the scene to neutral, which cancels the warm light along with any cast. Measured: the road, a true
neutral reference, read **R174 G176 B177 — very slightly cool**, in warm evening light.

That is not a defect (the result is colorimetrically correct and the grade can add warmth back),
but it is a choice being made at capture without realising it.

**Next time, decide deliberately:**

- Want the golden-hour warmth *in* the footage → lock WB to a **cooler** value than the scene
  (e.g. lock while pointed at something in shade, or set a fixed ~5600K), so the warm light reads
  as warm rather than being neutralised.
- Want maximum grading latitude → keep doing what you did. Neutral is the honest starting point;
  warmth added in the grade is reversible, warmth baked in is not.

Locked (rather than auto) is still right either way: it keeps every clip in the shoot consistent,
so one grade transfers across all of them. Auto WB would drift shot to shot and each clip would
need its own correction.

## Hold the phone consistently

**This shoot came back mixed-orientation and it broke the batch pipeline:**

| Rotation matrix | Clips | Presents as |
|---|---|---|
| none | IMG_0607, 0608, 0610–0618 (11) | 3840×2160 **landscape** |
| −90° | IMG_0619–0625 (7) | 2160×3840 portrait |
| +90° | IMG_0609 (1) | 2160×3840 portrait |

For vertical delivery this is a real problem: 11 clips can't go to 9:16 without discarding roughly
two-thirds of the frame width, and a script handed a landscape master will *silently* squash it
rather than error (fixed now — see BATCH_RUNBOOK — but it produced convincing-looking garbage
first).

**If the output is Reels/Stories, shoot vertical.** If a shot genuinely wants to be landscape,
that's fine — just know it is a different deliverable, and frame it knowing the vertical crop is
coming.

## Composition, for a 4:5 Feed crop

The Feed deliverable is 4:5, cropped from the 9:16 master — which means **the top and bottom of a
vertical frame will be cut**. Worth leaving headroom: don't put anything essential in the top or
bottom sixth if the shot is destined for Feed as well as Reels.

## Expose for the highlights, not the midtones

Log protects highlights well, and the grade pulls midtones down far more comfortably than it
recovers a clipped sky. On this shoot the brightest areas peaked at YMAX 854/1023 in the source —
comfortably unclipped, which left room to shape. Keep doing that.

## Getting the footage off the phone

Final Cut Camera stores its recordings **inside the app**, not in Photos — so Image Capture and the
Photos import both show nothing, which looks like a failed transfer. Export via the app's own
Library → Share → AirDrop (or Save to Files). Files land in `~/Downloads` from AirDrop.

Also: a charge-only USB cable will connect and charge while showing no device at all in Image
Capture. Worth ruling out early.

## Reference shots are worth ten seconds

Two things that would have saved real time here:

- **A grey card, or any known-neutral surface, in one frame per setup.** Turns white balance from
  a judgement into a measurement.
- **Something with a standardised colour in frame.** This shoot got lucky: a Dutch licence plate
  (RAL 1021), a traffic-red 30 ring (RAL 3020) and a traffic-blue parking sign (RAL 5017) all
  happened to be in shot, and they became the entire calibration basis — see PIPELINE.md. They also
  disproved several confident-but-wrong judgements made by eye. In a location without signage,
  shoot one frame with something of known colour in it.
