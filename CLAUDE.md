# WatchBeat

iOS app for measuring mechanical wristwatch beat rate accuracy via iPhone microphone.

## Git policy

This is a solo project with no PR review process. Push directly to `main` is the normal workflow — do not branch or open PRs unless explicitly asked. Tim has pre-authorized `git commit` and `git push origin main` against a clean working tree: proceed without confirmation prompts. Never force-push, never `git reset --hard` uncommitted work, never skip hooks.

## Project Structure

- **`WatchBeatCore/`** — Standalone Swift Package containing the entire DSP pipeline. Has **no iOS dependencies** (no AVFoundation, UIKit, SwiftUI). Depends only on `Accelerate` and `Foundation`. This is the enforcement boundary: if it imports an iOS framework, the design is wrong.
  - **`Sources/WatchBeatCore/`** — Pipeline stages and data types.
  - **`Sources/AnalyzeSamples/`** — CLI tool for offline analysis of saved WAV recordings.
  - **`Tests/WatchBeatCoreTests/`** — Synthetic signal tests, no device needed.
- **`WatchBeat/`** — Xcode iOS app project. Integration layer: audio capture (AVAudioEngine), real-time frequency monitor, session management, and SwiftUI views. Depends on `WatchBeatCore` as a local package.
- **`watchbeat-spec.md`** — Technical specification and algorithm reference.

## Build & Test

### DSP core (no simulator needed)
```bash
cd WatchBeatCore && swift build
cd WatchBeatCore && swift test
```

### iOS app
Open `WatchBeat/WatchBeat.xcodeproj` in Xcode. Build with Cmd+B, run on device for microphone testing.

## Architecture Rules

1. **WatchBeatCore must never import AVFoundation, UIKit, or SwiftUI.** The DSP pipeline operates on plain `[Float]` buffers with a known sample rate. All platform concerns live in the app layer.
2. **DSP components are pure functions of their inputs.** No singletons, no global state, no side effects. Each stage takes data in and returns results.
3. **Two pickers, one architecture.** The pipeline exposes `measureWithDiagnostics` (production picker, used by the AnalyzeSamples CLI) and `measureReferenceWithDiagnostics` (Reference picker, used by the iOS app). Both share the same shape: highpass → Envelope FFT (rate candidates) → Try-all-rates with guided tick extraction → Linear regression → MeasurementResult. They differ in candidate scoring, outlier rejection, and how they handle harmonic confusion (see rules 6 and 7). The Reference picker is the active one for the user-facing app; the production picker is preserved for offline diagnostics and corpus testing.
4. **Precision lives in the right place.** Period estimation uses decimated envelope (lower rate is fine). Tick localization uses full-rate raw signal (sub-sample precision matters).
5. **Synthetic signal generator is first-class.** Tests use `SyntheticTickGenerator` to produce signals with known ground truth. All pipeline tests should work without a microphone or device.
6. **Highpass yes, bandpass no.** Tick energy lives almost entirely above 4 kHz; room rumble, hum, mic self-noise, and broadband environmental noise (HVAC, washing machines) below that band actively confuse the envelope FFT's rate decision. Bandpass is out — cutting the high end loses the sharp-transient content that makes sub-sample tick localization possible. The Reference picker uses a single 5 kHz cutoff (`MeasurementPipeline.highpassCutoffHz`). The production picker runs dual-pass: 5 kHz for rate identification + 8 kHz for tick extraction on the winner's rate, with whichever pass yields higher quality winning. The dual-pass exists to rescue noisy-environment recordings (e.g. `Weak_Internal_q29` goes 29%→58% at 8 kHz) without regressing pin-lever Timexes that depend on the 5-8 kHz band; the Reference picker hasn't needed it because its scoring (rule 7) and its iterative outlier rejection (rule 8) already handle most of those cases.

7. **Harmonic disambiguation lives in candidate scoring.** Some watches emit a secondary audible event (rebound, echo, or precursor) at roughly half the beat period; the FFT can prefer the harmonic over the fundamental when the secondary is strong. The Reference picker handles this in its composite score, which multiplies confirmedFraction × quality × σ²-penalty × rateConsistency, where rateConsistency is a hard-cutoff factor that goes to zero if the regression slope deviates by more than 10% from the candidate rate's expected period. Wrong-rate candidates whose picker locks onto sub-events at the fundamental's spacing (rather than the candidate's own) are rejected by the rateConsistency cutoff before they can win. The production picker uses an explicit harmonic tiebreak instead: after picking a winner, it checks whether `winner.hz / 2` had a strictly larger envelope FFT magnitude (envRatio > 1.0); if so, it reports the lower rate but reuses the winner's tick data reinterpreted at 2× period, and suppresses beat error. Only exact 2× relationships among standard rates qualify — currently 18000 ↔ 36000 is the only such pair.

8. **Per-class quadratic-MAD outlier rejection (Reference picker).** A single bad pick (noise event in the gap, wrong sub-event) can bias OLS regression: outlier shifts slope, residuals carry an unmodeled trend, dots visibly diverge from the fitted line on the timegraph. The Reference picker fits a quadratic per class (tick / tock) — flexible enough to absorb genuine rate wandering — then drops beats whose residual from the quadratic exceeds 3 × 1.4826 × MAD (robust 3σ), floored at 5 ms. Iterates the fit-detect-drop cycle until stable (max 5 passes). The cleaned set drives the linear regression that produces the reported rate and beat error; outlier-rejected beats are also dropped from the displayed `tickTimings`.

## Standard Beat Rates

Mechanical only (quartz removed — 1Hz conflicts with heartbeat).

| bph   | Beat Hz | Oscillation Hz | Notes                    |
|-------|---------|----------------|--------------------------|
| 18000 | 5       | 2.5            | Vintage mechanical       |
| 19800 | 5.5     | 2.75           | Transitional vintage     |
| 21600 | 6       | 3              | Common vintage/modern    |
| 25200 | 7       | 3.5            | Less common              |
| 28800 | 8       | 4              | Most common modern       |
| 36000 | 10      | 5              | High-beat mechanical     |

**Hz convention**: The watch industry uses oscillation Hz (one oscillation = two beats). The `oscillationHz` property is for display; the `hz` property (beats/sec) is used internally by DSP.

## App Flow

1. **Idle** — Title + balance wheel logo, four positioning tips, "Listen" button.
2. **Monitoring** — FrequencyMonitor runs its own AVAudioEngine. Shows grow-window FFT bars from t≈0.5 s, refining as the window fills to 5 s. Wheel sits at 12:00. "Measure" button is disabled until 3 s have elapsed (FFT resolution stable enough to act on). User can wait longer for sharper bars.
3. **Recording** — AudioCaptureService takes over mic. Rolling 15-second analysis window every 3 seconds. Frequency bars continue via external feed. Balance wheel completes full 360° revolution over the 60 s budget. Auto-stops at 80% raw quality + 80% confirmedFraction + !isLowConfidence.
4. **Routing ladder** at end of recording (in order):
   - Gate 1: raw quality < 30% OR confirmedFraction < 50% OR tickTimings.count < 3 → **Weak Signal**
   - Gate 2: isLowConfidence (high per-class σ) → **Low Analytical Confidence**
   - Gate 3: rate-vs-snapped mismatch > 7% → **Unexpected Rate** (state `.rateConfusion`)
   - Gate 4: |rate| > 2000 s/day → **Watch Needs Service**
   - Gate 5: else → **Result** (rate dial, timegraph, beat error, amplitude)
5. **Result page** displays raw quality % weighted by confirmedFraction (cosmetic only — workflow logic uses raw fields). All failure pages have a **Try Again** button that returns to monitoring with a fresh 3 s gate.

## Key Conventions

- Beat error is nil for quartz watches (no tick/tock asymmetry). Currently only mechanical rates are supported.
- Rate error sign: positive = watch runs fast, negative = watch runs slow.
- Quality score (raw): `1 − exp(−SNR/10)` where SNR = medianTickEnergy / medianGapEnergy. Real watches saturate near 1.0; pure noise lands ~0.5–0.75.
- Displayed quality (cosmetic): `qualityScore × confirmedFraction`. Routing logic uses raw fields, not displayed.
- Quality thresholds (raw): ≥ 80% AND confirmedFraction ≥ 80% for auto-stop, ≥ 30% for the Weak Signal gate.
- Beat error color thresholds: < 1ms green, 1-3ms orange, > 3ms red.
- `AVAudioSession` must use `.measurement` mode to disable voice processing DSP.
- Audio capture: bottom mic, omnidirectional polar pattern, max input gain.

## App Layer Files

- **`ContentView.swift`** — Top-level state switch plus all screen views (IdleScreen, MonitoringScreen, RecordingScreen, AnalyzingScreen, ResultScreen, NeedsServiceScreen, RateConfusionScreen, ErrorScreen). Uses `SquareScreenLayout` generic view for consistent structure: title at top, flexible logo area, text/bars zone, fixed-height bottom control zone so buttons stay in the same position across screens. Observes `scenePhase` to release the mic when backgrounded. TimelineView(.animation) for 60fps recording animation.
- **`MeasurementCoordinator.swift`** — State machine (idle / monitoring / recording / analyzing / result / needsService / rateConfusion / error). Owns AudioCaptureService and FrequencyMonitor. `MeasurementConstants` enum provides shared thresholds, the `displayedQuality` helper (cosmetic), and quality color logic. `handleBackgrounded()` cleanly stops audio on app background.
- **`AudioCaptureService.swift`** — AVAudioEngine wrapper with RollingCollector actor (60-second buffer). AudioSessionConfigurator configures mic settings. Cleans up engine in deinit.
- **`FrequencyMonitor.swift`** — Real-time envelope FFT at each standard rate. Grow-window: FFTs the populated suffix of the rolling buffer (resolution grows from ~2 Hz at 0.5 s to 0.2 Hz at 5 s) so bars appear immediately rather than after a buffer-fill wait. Runs own engine during monitoring, switches to external feed during recording. Cleans up engine in deinit.
- **`FrequencyBarsView.swift`** — Bar chart visualization of power at each standard beat rate. Includes `formatOscHz` utility.
- **`ResultViews.swift`** — RateDialView (with beat error label: GOOD/FAIR/HIGH), TimegraphView (golden-ratio aspect), QualityBadgeView, GMTHandView, GMTMarkerView. All have VoiceOver accessibility labels.

## App Architecture

- **Portrait only on iPhone** — orientation locked in project settings. iPad target dropped (iOS 26 deprecated `UIRequiresFullScreen` workaround for iPad portrait-lock; the watch-against-bottom-edge interaction is iPhone-shaped anyway).
- **Stack-based adaptive layout** — VStack/Spacer approach instead of absolute positioning. `SquareScreenLayout` anchors the bottom control area at a fixed height so buttons don't shift between screens. Logo area flexes to fill remaining space. Works across iPhone SE through Pro Max.
- **Accessibility** — VoiceOver labels on rate dial, quality badge, timegraph, frequency bars, recording quality display, and all failure screens. Decorative logos hidden from VoiceOver.
- **Lifecycle** — Audio capture stops when app enters background via `scenePhase` observation.

## UI / UX Design Principles

These principles emerged from real bugs and confusion. They're as load-bearing as the DSP architecture rules above.

1. **Display values must match routing logic.** What the user sees on a meter or progress bar should be consistent with which page they end up on. If the bar shows 75% but the routing decides "weak signal" because of a hidden criterion, the user is confused. Display formula and gate formula must agree on what counts as "good enough" — even if implemented separately, they must reflect the same underlying intent.

2. **No DSP jargon in user-facing text.** "Sub-ms tick localization", "the algorithm", "secondary sub-events" belong in code comments, not on screens. Replace with what the user can act on: "Press firmly", "quieter ticks", "try a different position." Keep the literal navigation paths (Settings → Privacy & Security → Microphone) unchanged — those need exact strings.

3. **Each meaningfully-different failure gets its own state and screen.** When two error conditions need different recovery advice or a different header, give them separate `State` cases and separate views. Don't piggyback on a generic ErrorScreen with string-prefix detection — the bug that put "Snap Confusion" under the "Signal too weak" header is the cautionary tale.

4. **Show real-time feedback during waits.** A 5-second silent buffering period feels like the app froze. The grow-window FFT shows bars from t≈0.5 s and refines as the window fills — the user sees something happening immediately. Gate destructive-direction actions (Measure button) on time, not on visual emptiness.

5. **Cosmetic ≠ workflow.** Changing how a metric is displayed must never silently alter what the metric does internally. Display formulas (e.g. `qualityScore × confirmedFraction` for the bar) and routing gates (e.g. `qualityScore ≥ 30%` for Weak Signal) live in different code paths and are named differently — even when they happen to use the same fields.

6. **Routing ladder matches user mental model.** Three orthogonal questions: (a) are there enough meaningful ticks? → Weak Signal; (b) do the ticks make sense? → Low Analytical Confidence; (c) is the rate plausible? → Needs Service / Result. Each gate tests something a user could intuit. Don't introduce gates that mix categories or rely on internal-only signals the user can't predict.

7. **Idle screen sets up; failure screens recover.** Idle/Measure tips focus on what to DO ("Place the iPhone mic close to your watch"). Failure screens give recovery advice ("Quieter room", "Press firmly"). Don't repeat one in the other — users encountering each context need different framing.

8. **Imperative voice in tips.** Lead with the verb. "Try a different position" beats "If you have time, you might want to consider trying a different position." Drop hedging unless the qualifier is the point ("On-wrist readings are fine for general use" — the "fine" is the reassurance).

9. **Buttons stay put.** Across Idle, Monitoring, Recording, Result, and the various failure screens, the primary action button always lands at the same vertical position. The user doesn't have to relocate it between phases. `SquareScreenLayout` enforces this with a fixed-height bottom control zone.
