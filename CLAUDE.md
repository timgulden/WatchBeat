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
3. **Pipeline stages**: highpass (pre-filter, dual 5/8 kHz pass) -> Envelope FFT (rate identification) -> Try-all-rates with guided tick extraction -> Linear regression -> MeasurementResult
4. **Precision lives in the right place.** Period estimation uses decimated envelope (lower rate is fine). Tick localization uses full-rate raw signal (sub-sample precision matters).
5. **Synthetic signal generator is first-class.** Tests use `SyntheticTickGenerator` to produce signals with known ground truth. All pipeline tests should work without a microphone or device.
6. **Dual-cutoff highpass at the pipeline entry, no bandpass.** Tick energy lives almost entirely above 4 kHz; room rumble, hum, mic self-noise, and broadband environmental noise (HVAC, washing machines) below that band actively confuse the envelope FFT's rate decision. Different recordings have different sweet spots: 5 kHz HP preserves the 5-8 kHz band that pin-lever Timexes depend on; 8 kHz HP rescues noisy-environment recordings where mid-band junk dominates (e.g. `Weak_Internal_q29` goes from 29% → 58% at 8 kHz). Neither cutoff wins universally, so the pipeline runs both: primary pass at 5 kHz does rate identification; alternate pass at 8 kHz re-runs tick extraction for the winner's rate, and whichever pass yields higher quality wins. This recovers `Weak_Internal_q29` without regressing `Timex1_Strays` (99%) or `muddyticks` (58% — same as 5k-only; 8k alone would drop it to 18%). Bandpass remains out — cutting the high end loses the sharp-transient content that makes sub-sample tick localization possible. The cutoffs are `MeasurementPipeline.highpassCutoffHz` (5000) and `alternateHighpassCutoffHz` (8000).

7. **Harmonic-preference tiebreak for 2× rate ambiguity.** Some watches emit a secondary audible event (rebound, echo, or precursor) at roughly half the beat period — Tim's sick vintage Timex makes a distinct sub-click ~100 ms after each main tick. When mic placement captures the secondary strongly, a 2× rate fits the time domain *better* than the true fundamental (its regression locks cleanly to the 100 ms sub-period while the fundamental's drifts). The envelope FFT still sees the fundamental as the dominant bin. After the try-all-rates fit scorer picks an initial winner, a tiebreak checks whether a candidate at winner.hz / 2 had a strictly larger envelope FFT magnitude than the winner (envRatio > 1.0). If so, the pipeline reports the lower rate but reuses the winner's clean tick data reinterpreted at 2× period for accurate rate-error measurement. The candidate's own fit/recovery score is *not* gated — the failure mode being caught is exactly the case where the lower rate's standalone tick extraction does poorly because the secondary pulse out-competes the main tick at picking time. Beat error is suppressed in this path (the winner's even/odd split captures main-tick-vs-sub-pulse, not tick-vs-tock). Only exact 2× relationships among standard rates qualify — currently 18000 ↔ 36000 is the only such pair.

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

1. **Idle** — Title + balance wheel logo, "Listen" button.
2. **Monitoring** — FrequencyMonitor runs its own AVAudioEngine, shows real-time frequency bars at each standard rate. Balance wheel rotates slowly. "Measure" button.
3. **Recording** — AudioCaptureService takes over mic. Rolling 15-second analysis window every 3 seconds. Frequency bars continue via external feed. Balance wheel completes full revolution. Auto-stops at 80% quality or 60-second timeout.
4. **Result** — Rate dial (±120 s/day), timegraph, quality badge. Shows if quality >= 30%.
5. **Try Again** — Shown if quality < 30%. Helpful tips with SF Symbol icons.

## Key Conventions

- Beat error is nil for quartz watches (no tick/tock asymmetry). Currently only mechanical rates are supported.
- Rate error sign: positive = watch runs fast, negative = watch runs slow.
- Quality score 0...1 derived from regression residuals.
- Quality thresholds: >= 80% auto-stop, >= 30% show results, < 30% try again.
- Beat error color thresholds: < 1ms green, 1-3ms orange, > 3ms red.
- `AVAudioSession` must use `.measurement` mode to disable voice processing DSP.
- Audio capture: bottom mic, omnidirectional polar pattern, max input gain.

## App Layer Files

- **`ContentView.swift`** — Top-level state switch plus all screen views (IdleScreen, MonitoringScreen, RecordingScreen, AnalyzingScreen, ResultScreen, ErrorScreen). Uses `ScreenLayout` generic view for consistent structure: title at top, flexible logo area, text/bars zone, fixed-height bottom control zone so buttons stay in the same position across screens. Observes `scenePhase` to release the mic when backgrounded. TimelineView(.animation) for 60fps recording animation.
- **`MeasurementCoordinator.swift`** — State machine (idle/monitoring/recording/analyzing/result/error). Owns AudioCaptureService and FrequencyMonitor. `MeasurementConstants` enum provides shared thresholds and quality color logic. `handleBackgrounded()` cleanly stops audio on app background.
- **`AudioCaptureService.swift`** — AVAudioEngine wrapper with RollingCollector actor (60-second buffer). AudioSessionConfigurator configures mic settings. Cleans up engine in deinit.
- **`FrequencyMonitor.swift`** — Real-time envelope FFT at each standard rate. Runs own engine during monitoring, switches to external feed during recording. Cleans up engine in deinit.
- **`FrequencyBarsView.swift`** — Bar chart visualization of power at each standard beat rate. Includes `formatOscHz` utility.
- **`ResultViews.swift`** — RateDialView (with beat error label: GOOD/FAIR/HIGH), TimegraphView (golden-ratio aspect), QualityBadgeView, GMTHandView, GMTMarkerView. All have VoiceOver accessibility labels.

## App Architecture

- **Portrait only** — orientation locked in project settings.
- **Stack-based adaptive layout** — VStack/Spacer approach instead of absolute positioning. `ScreenLayout` anchors the bottom control area at a fixed height so buttons don't shift between screens. Logo area flexes to fill remaining space. Works across iPhone SE through Pro Max.
- **Accessibility** — VoiceOver labels on rate dial, quality badge, timegraph, frequency bars, and recording quality display. Decorative logos hidden from VoiceOver.
- **Lifecycle** — Audio capture stops when app enters background via `scenePhase` observation.
