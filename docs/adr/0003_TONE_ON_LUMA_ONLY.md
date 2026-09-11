# Apply the tone curve to luma only

A per-channel contrast curve crushes a saturated colour's two low channels harder than its high
one, so saturated things get more saturated — the traffic signage went neon, visibly, before it
was measured. That looked like an unavoidable trade (more contrast buys brick separation, costs
colorimetric accuracy) until the curve was applied to the luma plane with the original chroma
merged back. Same tone, blue back on spec, red no longer glowing:

| | YAVG | YMAX | brick R−B | blue B/G | red purity |
|---|---|---|---|---|---|
| per-channel | 534.8 | 853 | 22.0 | 2.34 | 0.29 (neon) |
| **luma-only** | 534.9 | 853 | 14.3 | **1.94** | **0.37** |

## Consequences

- Preserving chroma preserves it for everything, wanted or not: the brick gains no saturation
  either (R−B 14.3 vs 22.0). **Do not try to win that back with a uniform saturation boost** —
  tested, it lifts brick R−B to 18.7 and drags red purity 0.33 → 0.22, straight back to neon. A
  uniform multiplier amplifies whatever is already most saturated, which is the signage.
- Darkening alone still raises apparent saturation, because luma-only shaping lowers Y and leaves
  CbCr untouched. Gamma is the dial that trades "darker" against "less neon" (red purity 0.33 /
  0.30 / 0.27 across gamma 1.85 / 1.95 / 2.05).
- The Grade Bench applies its preview curve the same way. If one changes, the other must, or the
  preview stops predicting the render.
