# WatchBeat

iOS app for measuring mechanical wristwatch beat-rate accuracy with the
iPhone microphone.

Hold the watch against the bottom edge of an iPhone, tap **Measure**, and
the app reports rate error (seconds per day), beat error (tick / tock
asymmetry in milliseconds), amplitude (degrees), and a per-tick timegraph.
Auto-detects the standard mechanical beat rate (18000 / 19800 / 21600 /
25200 / 28800 / 36000 bph). Quartz watches not supported (1 Hz tick
conflicts with heartbeat).

## Repository layout

- **`WatchBeatCore/`** — Swift Package with the entire DSP pipeline.
  Has **no iOS dependencies** — depends only on `Accelerate` and
  `Foundation`. Build and test on macOS via `swift build` / `swift test`
  (no simulator or device needed).
  - `Sources/WatchBeatCore/` — pipeline stages, data types, and
    protocols (`MeasurementPipeline`, `BeatPicker`, `MeasurementResult`,
    `AmplitudeEstimator`, etc.).
  - `Sources/AnalyzeSamples/` — CLI tool for offline analysis of saved
    `.wav` recordings. Run `swift run AnalyzeSamples path/to/recording.wav`.
  - `Sources/Reference/`, `Sources/Fourier/`, `Sources/TickAnatomy/`, etc.
    — diagnostic CLIs used during algorithm development.
  - `Tests/WatchBeatCoreTests/` — synthetic-signal tests (~90 tests),
    no microphone needed.
- **`WatchBeat/`** — Xcode iOS app project. Integration layer: audio
  capture (AVAudioEngine), real-time frequency monitor, session
  management, SwiftUI views. Depends on `WatchBeatCore` as a local
  package.
- **`watchbeat-spec.md`** — full technical specification: signal model,
  pipeline architecture, error budget, per-stage rationale.
- **`CLAUDE.md`** — project-specific instructions and design principles
  (DSP architecture rules + UI/UX principles).
- **`ARCHITECTURE_REMEDIATION.md`** — phased plan tracking ongoing
  code-quality improvements. Phases 1, 2, and most of 3 complete.

## Build & test

### DSP core (no simulator needed)

```bash
cd WatchBeatCore
swift build
swift test
```

### iOS app

Open `WatchBeat/WatchBeat.xcodeproj` in Xcode (16+). Build with `Cmd+B`,
run on a real device for microphone testing — the simulator's mic doesn't
capture watch-frequency content well.

iPhone-only target (portrait-locked, since the user holds the watch
against a specific edge of the phone).

### Offline corpus analysis

The `AnalyzeSamples` CLI processes saved recordings from the
`SoundSamples/` directory:

```bash
WATCHBEAT_LIFT_ANGLE=40 WatchBeatCore/.build/debug/AnalyzeSamples \
    SoundSamples/TimexTickTick.wav
```

Environment variables:
- `WATCHBEAT_REFERENCE=1` — use the Reference picker (matches what the
  iOS app uses) instead of the production picker
- `WATCHBEAT_LIFT_ANGLE=40` — set lift angle for amplitude calculation
  (default 52° for Omega; 40° for vintage Timex pin-levers)
- `WATCHBEAT_DEBUG_CANDIDATES=1` — dump per-rate candidate scores
  during Reference picker run

## Design highlights

- **Strict DSP/iOS boundary.** The `WatchBeatCore` package can't import
  AVFoundation, UIKit, or SwiftUI — enforced structurally, not by
  convention. All platform concerns live in the iOS app layer.
- **Pure-function pipeline stages.** Components take data in and return
  results — no singletons, no global state. Tests run on synthetic
  signals with known ground truth.
- **Two pickers, one architecture.** Production picker (`measure`,
  `measureWithDiagnostics`) preserved for offline diagnostics; Reference
  picker (`measureReference`, `measureReferenceWithDiagnostics`) is what
  the iOS app uses. Both adopt the `BeatPicker` protocol.
- **Per-class quadratic-MAD outlier rejection** in the Reference picker
  catches single bad picks (noise events in gaps, wrong sub-events)
  without sacrificing genuine rate wandering. See
  `Sources/WatchBeatCore/OutlierRejector.swift`.
- **Composite candidate scoring** disambiguates harmonics in the
  Reference picker via a `rateConsistency` factor (slope-vs-expected-
  period cutoff). See `Sources/WatchBeatCore/ReferenceCandidate.swift`.

For the algorithm details, read `watchbeat-spec.md`. For the project
conventions and design principles, read `CLAUDE.md`.

## Status

Active development. Solo project — pushes go directly to `main`, no PRs.
See `ARCHITECTURE_REMEDIATION.md` for the ongoing code-quality work.
