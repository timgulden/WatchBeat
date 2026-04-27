# TickAnatomy investigation notes

Long-form notes from research sessions using TickAnatomy + plot_onsets to
investigate watches the production pipeline reads as disordered, unstable,
or otherwise puzzling. Newest entries at the top.

These are observations from individual cases, not generalized claims. The
sample size is small. Treat each entry as "one watch did this on one
recording on one date" until corroborated.

---

## 2026-04-26 — Timex2 disordered ticks → near-stall, resolved by oil + winding

**Symptom:** Cleaned and oiled Timex2 was producing disordered ticks and
intermittently wrong rate readings. Beat rate often reported close to the
true 18000 bph but never quite right; ticks would not regress cleanly.

**Investigation:**
- Built spectral-flux + multiple onset-detection variants in TickAnatomy
  (`spectralFlux`, per-tick traces in `PerTickTrace`).
- Compared against production picker on `Timex2Disorder_18000bph_q100.wav`
  and `Timex2Odd_18000bph_q99.wav`.
- Production picker (smoothed-argmax + centroid + lock-in) had per-class
  σ ≈ 2-3 ms. Every alternative detector tested came in 4-6 ms because
  they re-anchor on a sharper envelope that flips between sub-events.
- BE was small in absolute terms (0.05-0.97 ms) but per-class σ was much
  larger, which is precisely the condition that fires the disorderly flag.

**Resolution (mechanical, not algorithmic):** Tim noticed Timex2 had stalled
mid-test despite being nearly fully wound. Topping up the winding restored
healthy amplitude. Watch then ran cleanly — beat error ~2 ms, regulation
within seconds/day dial-down, within a minute/day in other positions.
**The pipeline started reading it correctly without any code changes.**

**Conjecture (one data point, do not generalize):** Disorderly flag may
correlate with very-low-amplitude / near-stall behavior in mechanical
watches. The chain would be: low amplitude → variable energy per tick →
inconsistent escapement event amplitudes → sub-events of similar
amplitude → picker can't lock onto a consistent feature → high per-class
σ → disorderly. But this is one watch on one day. Healthy watches can
also fire disorderly under bad acoustic conditions (loud environment,
poor mic contact), and unhealthy watches can read cleanly when the
specific failure mode happens not to perturb tick timing. Not a rule.

**What we did NOT change:**
- Production picker (no edits to `MeasurementPipeline.swift`)
- Disorderly flag logic (still fires on residual variance pattern)
- UI (still shows "---" / "ERROR" when disorderly — this is the right
  behavior; preserve it)

**What we DID add (research-only, no production impact):**
- `PerTickTrace` struct and per-tick onset detection variants in
  `Sources/TickAnatomy/main.swift`
- Spectral flux STFT helper (`spectralFlux` function)
- `plot_onsets.py` for visualizing per-tick stability and BE diagnostic

**Data files retained for reference:**
- `Timex2Disorder_18000bph_q100.{wav,onsets.json,onsets.png,anatomy.{csv,json,png}}`
- `Timex2Odd_18000bph_q99.{wav,onsets.json,onsets.png,anatomy.{csv,json,png}}`
