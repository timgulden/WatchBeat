# Reference picker — open design questions

## FFT-magnitude-rate fallback (deferred 2026-05-01)

### Problem

The Reference picker reports rate via linear regression on the per-window
argmax positions. On clean recordings this works well — picks are tight,
regression slope is precise. On lossy recordings (e.g., YouTube playback
through a MacBook speaker captured by phone mic — see EbayVid.wav), the
per-window argmax gets pulled around by noise spikes during sections
where the watch ticks are obscured. The result: σ blows out (43–56 ms
on EbayVid even at the right rate), the regression slope is biased by
the noise picks, and the rate becomes unreliable.

But the FFT itself is robust to such localized noise — the watch's
periodic component is integrated over the full 15 seconds. The
parabolic-interpolated peak frequency on EbayVid gives roughly
6.16 Hz, which after subtracting nominal 6.0 Hz (21600 bph) yields
~+1500–2300 s/day, in the same ballpark as the production picker's
+10.9 s/day. Direction is right; precision differs because Hann
windowing of a 15 s envelope has a main-lobe width of ~0.13 Hz, which
at 6 Hz corresponds to ±19 s/day — much smaller than the regression's
error on this recording.

### Idea

When `isLowConfidence == true` (σ > 10 ms after the chosen rate), the
regression-derived rate is suspect but the FFT-derived rate is still
usable. Report the FFT rate as the primary number, flag the result with
a caveat ("rate from FFT, picker couldn't lock on individual ticks"),
and skip the timegraph (or draw it dimmed).

### Sketch

In `MeasurementResult` add a flag `rateFromFFT: Bool` (default false).

In `measureReferenceWithDiagnostics`, after the winner is picked but
before computing rateErrPerDay, branch on `winner.avgClassStd > 10`:

```swift
if winner.avgClassStd > 10.0 {
    // Per-tick picker can't lock; fall back to FFT-magnitude rate.
    let rateErrPerDay = (winner.fHz / snappedRate.hz - 1.0) * 86400.0
    // ... build result with rateFromFFT: true, beatError: nil
} else {
    // Use regression slope.
    let rateErrPerDay = (1.0 / slope / snappedRate.hz - 1.0) * 86400.0
    // ... regular result
}
```

In `MeasurementCoordinator`, when `result.rateFromFFT == true`, route
to a NEW result variant — maybe a "Rate-only" page that shows the rate
prominently and marks beat error / amplitude / timegraph as
"unavailable for this recording." Or just include a small inline note
on the regular result page.

### Concerns to think through

1. **When does FFT rate disagree with regression rate by more than the
   FFT main-lobe width?** If the answer is "never on real recordings,"
   the fallback is purely additive (covers cases regression failed). If
   "sometimes," we need to choose which to trust. Production already
   picks regression; need to understand its scenarios.

2. **Beat error from FFT alone** isn't directly available. The
   sub-harmonic phase gives some BE info (see Fourier tool's experiment
   from 2026-04-30) but we showed it's hard to extract robustly. So if
   we use FFT-rate, we'd report `beatErrorMilliseconds: nil` and let
   the UI show "—" for BE.

3. **Timegraph plot** depends on per-tick residuals. If the picker
   couldn't lock cleanly, the residuals are mostly noise. Probably
   should not show the timegraph in the FFT-fallback path. UI tells
   user "rate is reliable, beat-error couldn't be measured this time."

4. **σ threshold for fallback**: 10 ms (the current isLowConfidence
   threshold) might be the right boundary. Recordings cleaner than
   that give a regular result; noisier ones use FFT-rate fallback.

### Cost estimate

Maybe 50 lines in `MeasurementPipeline.swift`, 30 lines in
`MeasurementCoordinator.swift`, plus UI variant in `ContentView.swift`.
Half a session of work, plus testing on a corpus that includes both
clean and lossy recordings.

### Test fixtures needed

- A clean recording (e.g., OmegaTrending) — should NOT trigger fallback.
- A lossy recording (e.g., EbayVid) — should trigger fallback with a
  rate close to production's reading.
- A near-stall recording (e.g., a current OmegaBad-state recording) —
  fallback should still flag low-confidence and probably route to the
  "low analytical confidence" page, NOT show a rate-only result.

The third case is the tricky one — fallback is "rate is right but timing
is messy" while low-confidence is "rate is right but watch is stalling."
Both have high σ; what separates them is whether the user did something
wrong vs the watch is broken. May need additional signal (confirmedFraction
high but σ moderate vs σ very high?).
