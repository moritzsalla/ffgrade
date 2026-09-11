# Keep Apple's CST rather than the from-scratch filmic route

The textbook-correct architecture is to decode Apple Log to scene-linear, apply a filmic tone
curve in linear where highlight rolloff and shadow density behave properly, and encode to
Rec.709 — Apple Log carries linear values to 12× diffuse white and the technical CST compresses
all of that away. That route was built (`make-filmic-lut.py`) and it did produce a better tone
response, using far more of the range (YMAX 943 vs 745). It lost on colour and is not what ships.

## Considered options

- **1D LUT, log→linear only.** Impossible: Apple Log is in BT.2020 primaries and a 3×3 gamut
  matrix is not expressible as a per-channel curve. Measured brick spread 4.6 against the CST's
  17.0 — badly under-saturated, because BT.2020 numbers read as Rec.709 desaturate.
- **3D LUT with the gamut matrix at 65³.** Better, still only spread 8.6. Per-channel tone mapping
  desaturates by construction, so a global saturation multiplier was added to compensate — which
  overshot the standardised blue to B/G 2.45 against a 1.98 spec.
- **Apple's CST, tone shaped afterwards in display space.** Blue at 1.97, more brick separation.
  Shipped.

Apple's gamut handling is better colour science than anything hand-rolled here, and the
standardised references are what proved it rather than a preference.

## Consequences

Display-space shaping cannot recover highlight detail the CST has already compressed. It is
workable because the CST does not clip on this footage (YMAX 884/1023), so there is room to shape.
`make-filmic-lut.py` and `luts/filmic/` are kept: the architecture is right and may win with
proper gamut mapping. They are a dead end on record, not dead code to delete.
