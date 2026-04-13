# WatchBeat

iOS app for measuring wristwatch beat rate accuracy via microphone recording.

## Project Structure

- **`WatchBeatCore/`** — Standalone Swift Package containing the entire DSP pipeline. Has **no iOS dependencies** (no AVFoundation, UIKit, SwiftUI). Depends only on `Accelerate` and `Foundation`. This is the enforcement boundary: if it imports an iOS framework, the design is wrong.
- **`WatchBeat/`** — Xcode iOS app project. Thin integration layer: audio capture (AVAudioEngine), session management, and SwiftUI views. Depends on `WatchBeatCore` as a local package.
- **`watchbeat-spec.md`** — Full technical specification. Authoritative reference for algorithm details, signal model, test plan, and error budget.

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
3. **Pipeline stages** (in order): SignalConditioner -> PeriodEstimator -> TemplateBuilder -> TickLocator -> RateAnalyzer -> MeasurementResult
4. **Precision lives in the right place.** Period estimation uses decimated envelope (lower rate is fine). Tick localization uses full-rate raw signal (sub-sample precision matters).
5. **Synthetic signal generator is first-class.** Tests use `SyntheticTickGenerator` to produce signals with known ground truth. All pipeline tests should work without a microphone or device.

## Standard Beat Rates

| bph   | Hz | Notes                        |
|-------|----|------------------------------|
| 3600  | 1  | Quartz                       |
| 14400 | 4  | Half-speed mechanical        |
| 18000 | 5  | Vintage mechanical           |
| 21600 | 6  | Common vintage/modern        |
| 25200 | 7  | Less common                  |
| 28800 | 8  | Most common modern           |
| 36000 | 10 | High-beat mechanical         |

## Key Conventions

- Beat error is nil for quartz watches (no tick/tock asymmetry).
- Rate error sign: positive = watch runs fast, negative = watch runs slow.
- Quality score 0...1 derived from regression residuals.
- Target precision: +/-1 second/day on clean 28800 bph signal over 30-second capture.
- `AVAudioSession` must use `.measurement` mode to disable voice processing DSP.
