# Per-class FFT-anchored amplitude — research notes (2026-04-30)

## Status

Prototype only. **Not in production.** The production iOS app uses the
existing `AmplitudeEstimator` pulse-width method
(`measurePulseWidths` → 20%-of-peak full-width). The work below is a
parallel research direction that may replace or complement it once
calibrated against a real timegrapher (Tim ordered one, arrives 2026-05-01).

## Motivation

The existing pulse-width method measures the *full-width* of the dominant
acoustic peak at 20% of its height. On Omega 485 this gives ~5 ms,
yielding amplitude readings of 250–330° — values that look healthy but
seem too high for a watch that's been visibly weak (sometimes
near-stalling) for the length of our ownership.

Tim's hypothesis was that a Witschi-equivalent measurement should use
**sub-event spacing** rather than peak width. The standard amplitude
formula uses `t_pulse` = "time the balance takes to traverse the lift
angle" = unlock-to-lock duration. Acoustically that's the distance
between the *first* escapement event (pallet unlocks the escape tooth)
and the *last* escapement event (next escape tooth locks against the
opposite pallet). Two events bound the impulse phase; the drop event
sits in the middle.

## Algorithm

Operates on the per-class average envelope (`evenShape`/`oddShape`)
that the Reference picker already computes — peak-aligned to the
dominant sub-event in each beat, then averaged across all beats of
the class.

```
1. Find local maxima in the class envelope (5-sample neighborhood).
2. Reject anything within ±5 ms of the dominant (decay tail).
3. Reject anything beyond ±25 ms (out of physical range).
4. Cluster surviving peaks: peaks within 2 ms of each other are the
   same physical sub-event seen at multiple sample positions.
5. Filter to "significant" sub-events: cluster amplitude ≥ 3% of
   dominant. Below that they're likely noise.
6. Compute pulse width based on what's visible:
     - 2+ significant secondaries:
         pulse = distance from dominant to FARTHEST secondary
       (interpretation: dominant is the lock event, farthest is the
        unlock; distance = unlock-to-lock = full lift-angle traversal)
     - 1 significant secondary, distance < 14 ms:
         pulse = 1.6 × distance
       (single secondary that close is probably the middle drop event;
        extrapolate to full unlock-to-lock by the empirical Swiss
        sub-event spacing ratio)
     - 1 significant secondary, distance ≥ 14 ms:
         pulse = distance directly
       (single secondary that far is the unlock; already gives the
        full unlock-to-lock)
     - 0 significant secondaries: cannot measure (return nil).
7. Compute amplitude per class:
     A = lift_angle / (2 · sin(π · pulse / beat_period))
8. Average tick and tock amplitudes if both are valid.
```

## Empirical anchors (from OmegaTrending)

For Omega 485 in the OmegaTrending recording (the cleanest baseline),
all three sub-events were directly observable in the per-class shape:

```
peak position   amplitude   identity
   -19 ms         0.023     unlock (small, earliest)
   -12 ms         0.090     drop   (middle, biggest non-dominant)
     0 ms         1.000     lock   (huge, dominant — peak-aligned to here)
```

Spacings: unlock→drop = 7 ms, drop→lock = 12 ms.
Sum (unlock→lock) = 19 ms.
Ratio (drop-to-lock) ÷ (unlock-to-lock) = 12/19 ≈ 0.63.
So unlock-to-lock ≈ 1.6 × drop-to-lock — hence the 1.6 multiplier in
the algorithm.

## Tunable parameters

Three constants that could (and probably will) need calibration when
the real timegrapher data arrives:

1. **Ratio constant `1.6`** in step 6's `pulse = 1.6 × distance` case.
   Derived from Omega 485 sub-event geometry. Other calibers may have
   different ratios — vacaboja's source code is one reference; per-caliber
   timegrapher comparison is the gold standard.
2. **Significance threshold `3%`** in step 5. Below this, peak clusters
   are treated as noise. On weak-recording watches, real sub-events may
   fall below 3% — in that case the algorithm sees only one secondary
   and falls back to the spacing-based heuristic. Lowering this might
   detect more sub-events but admits more noise.
3. **Distance threshold `14 ms`** in step 6 for distinguishing
   "middle (drop)" from "far (unlock)" peaks. Set by the empirical
   midpoint of Omega 485's drop-to-lock (~12 ms) and unlock-to-lock
   (~19 ms). Will likely need adjustment for higher-rate calibers
   (28800/36000 bph) where physical sub-event spacings shrink.

## Validation on OmegaStudy corpus (2026-04-30)

15 recordings of the Omega 485 in different positions, all with the
algorithm's parameters tuned from OmegaTrending only:

```
12U1 73°   12U2 62°   12U3 74°       (12 o'clock up — vertical)
6U1  73°   6U2  66°   6U3  62°       ( 6 o'clock up — vertical)
CD1  81°   CD2  65°   CD3  73°       (crown down — vertical)
DD1  86°   DD2  69°   DD3  69°       (dial down — horizontal)
DU1  70°   DU2  81°   DU3  83°       (dial up   — horizontal)
OmegaTrending  73°
```

All values above 52° (the lift angle), so physically possible (a watch
needs amplitude > lift angle to tick at all).

Position spread: best ~83° (DU3), worst ~62° (12U2/6U3). Δ ≈ 21°. For a
healthy watch Δ across positions is typically 20–60°, so this is
within normal range.

Mean ~72°. For a healthy Omega 485 we'd expect 250–280° wound.
This watch reads 1/3 of healthy — consistent with Tim's standing
diagnosis that the movement has been weak the whole time we've owned
it. It's going to Nesbit's Fine Watch Service for full evaluation.

## Comparison vs production pulse-width method

| File | Production | Per-class FFT |
|---|---:|---:|
| OmegaTrending | 192° | **73°** |
| OmegaTrouble | 235° | (not run yet) |
| TimexTickTick | 280° | (not yet — needs Timex tuning) |
| Timex3Weak | 271° | (not yet) |

The production method gives ~3× higher readings. Without timegrapher
ground truth we don't know which is right; on physical grounds the
per-class method's lower reading is more consistent with the watch's
visible mechanical state, but the production method's reading is more
consistent with industry timegrapher conventions for *healthy* watches.
The truth probably lies somewhere between; this watch may genuinely be
weak AND the per-class algorithm's ratio constants may be slightly off.

## Things to do once the timegrapher arrives

1. **Anchor the 1.6 ratio.** Compare timegrapher's amplitude reading
   against per-class FFT for OmegaTrending. The "correct" ratio is
   whatever gives matching numbers.
2. **Test on Tim's Timex collection.** Pin-lever ticks have different
   acoustic structure (often single peak); the algorithm should fall
   back to nil. Verify it does, and consider how to combine with
   pulse-width method as a fallback.
3. **Test on a healthy Swiss reference watch** (if Tim has one or
   borrows one). All three parameters might tune slightly differently.
4. **Once tuned, port to Swift** in `AmplitudeEstimator.swift` as
   `measurePulseWidthsFromShape`. Gate on per-class shape having a
   detectable secondary peak: clean Swiss → use FFT method, single-peak
   pin-lever → fall back to existing pulse-width.

## Files

- `per_class_amplitude.py` — the prototype implementation. Run on any
  `<file>.reference.json` produced by the Reference CLI.
- This document.
