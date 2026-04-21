# WatchBeat

iOS app for measuring mechanical wristwatch beat rate accuracy via iPhone microphone.

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
3. **Pipeline stages**: 5 kHz highpass (pre-filter) -> Envelope FFT (rate identification) -> Try-all-rates with guided tick extraction -> Linear regression -> MeasurementResult
4. **Precision lives in the right place.** Period estimation uses decimated envelope (lower rate is fine). Tick localization uses full-rate raw signal (sub-sample precision matters).
5. **Synthetic signal generator is first-class.** Tests use `SyntheticTickGenerator` to produce signals with known ground truth. All pipeline tests should work without a microphone or device.
6. **5 kHz highpass at the pipeline entry, no bandpass.** Empirically validated across a mix of marginal internal-mic and headphone-mic recordings: 5 kHz HP recovered every previously-failing file (14/17 → 17/17 passing) without hurting any strong one. Tick energy lives almost entirely above 4 kHz; room rumble, hum, and mic self-noise below that band actively confuse the envelope FFT's rate decision. Bandpass remains out — cutting the high end loses the sharp-transient content that makes sub-sample tick localization possible. The cutoff is `MeasurementPipeline.highpassCutoffHz`.

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
