#!/usr/bin/env python3
"""
Generate a 1D .cube LUT: a filmic S-curve applied in DISPLAY space (Rec.709 in, Rec.709 out).

WHY THIS AND NOT THE OTHER ONE
------------------------------
make-filmic-lut.py replaces Apple's CST entirely, doing log -> linear -> tonemap -> Rec.709. That
is the textbook-correct architecture and it produces a better *tone* response, but it lost on
*colour*: a naive BT.2020->709 matrix plus a global saturation multiplier could not match Apple's
CST, which lands the standardised traffic-blue at B/G 1.97 against a 1.98 spec while keeping more
brick separation. Apple's gamut handling is better than anything hand-rolled here.

So: keep Apple's CST for colour, and do the tone shaping afterwards with this. Display-space
shaping cannot recover highlight detail the CST already compressed, but the CST does not clip
(measured YMAX 884/1023 on this footage), so there is room to work.

Why a generated 1D LUT rather than ffmpeg's `curves` filter: `curves` interpolates control points
with a cubic spline that overshoots past identity when the slope between segments is uneven —
this pipeline hit that twice, once producing an image *brighter* than the uncorrected version.
A 4096-entry 1D LUT is evaluated exactly, with no interpolation surprises.

Apply with ffmpeg's `lut1d` filter.

USAGE
    ./make-tone-lut.py OUT.cube [--pivot 0.42] [--contrast 1.25]
                                [--toe 0.30] [--shoulder 0.30] [--black 0.0]

    --gamma     midtone level, applied FIRST: v = x**gamma. >1 darkens. Needed because contrast
                pivoted about a point BELOW the image's own average brightens rather than
                shapes it — this footage averages 0.65, so a 0.42 pivot alone made it brighter.
                Set gamma so the average lands near the pivot, then let contrast do the shaping.
    --pivot     tonal level held (roughly) fixed while contrast pivots around it.
    --contrast  slope at the pivot. >1 increases contrast.
    --toe       how much the shadows roll off instead of clipping. Higher = softer, more film-like
                shadow; 0 = hard linear into black.
    --shoulder  same for highlights. This is what stops bright areas going to flat paper-white.
    --black     black point lift (>0) or crush (<0), applied last.
"""
import argparse

SIZE = 4096


def soft(x, k):
    """Smooth compression toward 0..1 with strength k; k=0 is a no-op."""
    if k <= 0:
        return max(0.0, min(1.0, x))
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    # a gentle sigmoid-ish squash that preserves the midsection
    return x + k * (x * x * (3 - 2 * x) - x)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--gamma", type=float, default=1.0)
    ap.add_argument("--pivot", type=float, default=0.42)
    ap.add_argument("--contrast", type=float, default=1.25)
    ap.add_argument("--toe", type=float, default=0.30)
    ap.add_argument("--shoulder", type=float, default=0.30)
    ap.add_argument("--black", type=float, default=0.0)
    a = ap.parse_args()

    lines = [
        f'TITLE "Filmic tone shaping (pivot={a.pivot} contrast={a.contrast} '
        f'toe={a.toe} shoulder={a.shoulder} black={a.black})"',
        "",
        f"LUT_1D_SIZE {SIZE}",
        "",
    ]
    for i in range(SIZE):
        x = i / (SIZE - 1)

        # level first, then contrast pivoted about `pivot`
        v = x ** a.gamma if a.gamma != 1.0 else x
        v = (v - a.pivot) * a.contrast + a.pivot

        # roll off each end rather than clipping
        if v < a.pivot:
            t = v / a.pivot if a.pivot > 0 else 0.0
            v = soft(max(0.0, t), a.toe) * a.pivot
        else:
            span = 1.0 - a.pivot
            t = (v - a.pivot) / span if span > 0 else 0.0
            v = a.pivot + soft(max(0.0, min(1.0, t)), a.shoulder) * span

        v = v * (1.0 - a.black) + a.black
        v = max(0.0, min(1.0, v))
        lines.append(f"{v:.8f} {v:.8f} {v:.8f}")

    open(a.out, "w").write("\n".join(lines) + "\n")
    print(f"wrote {a.out} ({SIZE}-entry 1D LUT)")


if __name__ == "__main__":
    main()
