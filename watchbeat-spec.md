# WatchBeat: Technical Specification

## 1. Goals and Non-Goals

### Goals

- Measure the rate error of a running mechanical wristwatch from a continuous microphone recording (up to 60 seconds) taken by pressing an iPhone against the watch caseback.
- Report rate error in seconds per day, relative to the nearest standard beat rate.
- Auto-detect the nominal beat rate from the set of standard mechanical values.
- Report beat error (tick/tock asymmetry) in milliseconds.
- Provide a measurement quality indicator and real-time frequency visualization.
- Target precision: ±1 second/day on a clean 28800 bph signal over a 15-second analysis window.

### Non-Goals

- Full watch health diagnosis beyond quality/jitter metric.
- Lift angle estimation or precise amplitude measurement in degrees.
- Positional analysis (dial up, crown down, etc.).
- Rate tracking over long periods or across multiple sessions.
- Support for non-standard beat rates outside the enumerated set.
- Quartz watch support (removed due to 1Hz heartbeat confusion).

## 2. Design Philosophy

**Separation of concerns.** The DSP pipeline has no knowledge of iOS, AVFoundation, UI, or audio capture. It operates on plain `[Float]` buffers with a known sample rate. The iOS integration layer is thin and does only what requires platform APIs: microphone access and buffer delivery.

**Testability first.** Every DSP component is a pure function of its inputs where possible. The synthetic signal generator is a first-class component, not an afterthought. Tests run on macOS via `swift test` without a simulator or device.

**Package boundary as enforcement.** The DSP core lives in a standalone Swift Package that does not depend on AVFoundation, UIKit, or any iOS-specific framework. This makes the separation structural rather than conventional — violations fail to compile.

**Trust the FFT for rate identification, then verify with per-rate fit.** Envelope FFT generates candidates; the per-rate fit scorer (recoveryRate × residualQuality × periodConsistency × envBoost) picks the winner across every standard rate. FFT magnitude ordering alone is never trusted — at higher highpass cutoffs the 2nd harmonic of 18000 bph (10 Hz) can outscore the fundamental (5 Hz) in the envelope FFT, and only the time-domain fit catches that. An 8 kHz Butterworth highpass at the pipeline entry removes LF rumble, hum, mic self-noise, and broadband environmental noise (HVAC, washing machines) that would otherwise bias rate identification; tick energy lives almost entirely above 4 kHz. Bandpass is avoided because the high-end content carries the sharp-transient information that makes sub-sample tick localization possible.

**Precision lives in the right place.** Period estimation uses a decimated envelope because it only needs to find a repetition rate. Tick localization uses the full-rate raw signal because that is where sub-sample precision comes from. Each stage uses the representation best suited to its job.

## 3. Signal Model

### Beat rates

The app recognizes the following standard mechanical beat rates:

| bph   | Beat Hz | Oscillation Hz | Notes                    |
|-------|---------|----------------|--------------------------|
| 18000 | 5       | 2.5            | Vintage mechanical       |
| 19800 | 5.5     | 2.75           | Transitional vintage     |
| 21600 | 6       | 3              | Common vintage/modern    |
| 25200 | 7       | 3.5            | Less common              |
| 28800 | 8       | 4              | Most common modern       |
| 36000 | 10      | 5              | High-beat mechanical     |

**Hz convention**: The watch industry uses oscillation frequency (one oscillation = two beats). 28800 bph = 8 beats/sec = 4 oscillations/sec = "4 Hz" in watch terminology. The `hz` property gives beats/sec (for DSP); the `oscillationHz` property gives oscillations/sec (for display).

Detected rate is always snapped to the nearest value in this set. Rate error is reported as the deviation of the measured period from the nominal period of the snapped rate, converted to seconds per day.

### Tick structure

A single mechanical watch "tick" is a compound acoustic event from the escapement with three distinguishable sub-events (unlock, impulse, drop) spanning approximately 3–5 ms. The acoustic energy is concentrated roughly in the 3–8 kHz band, though this varies by movement. The balance wheel oscillates in two directions, and the acoustic signature of the two half-cycles ("tick" and "tock") is not identical. The asymmetry between them is the physical basis of beat error.

### Precision target

Targeting ±1 second/day on a 28800 bph signal means resolving the period to about 1 part in 86400. At 48 kHz sampling, one sample is about 21 microseconds, and the nominal tick period at 8 Hz is 6000 samples. Sub-sample precision via interpolation, combined with linear regression over ~120 ticks in a 15-second window, comfortably reaches this target on clean signals.

## 4. Pipeline Architecture

### Component overview

```
AudioCapture            [iOS layer, AVAudioEngine, 48 kHz]
    |
    v
  Float buffer + sample rate
    |
    v
Envelope FFT            rectify + lowpass 50Hz + decimate to ~1kHz + FFT
    |                   Score each standard rate by spectral magnitude.
    v                   If clear winner (>30% margin), trust it directly.
Try-All-Rates           Otherwise, try all 6 rates with guided tick extraction.
    |                   Score: recoveryRate × residualQuality × periodConsistency × envBoost
    v
Guided Tick Extraction  Divide raw signal into beat-length windows (20% width).
    |                   5 offset tries, median alignment, energy-peak detection.
    v
Linear Regression       Fit tick index vs tick time. Slope = measured period.
    |                   Deviation from nominal = rate error in s/day.
    v                   Even/odd residual offsets = beat error.
MeasurementResult       Rate, rate error, beat error, quality, tick timings.
```

### Data types

```swift
public struct AudioBuffer {
    public let samples: [Float]
    public let sampleRate: Double
}

public enum StandardBeatRate: Int, CaseIterable, Sendable {
    case bph18000 = 18000
    case bph19800 = 19800
    case bph21600 = 21600
    case bph25200 = 25200
    case bph28800 = 28800
    case bph36000 = 36000

    public var hz: Double { Double(rawValue) / 3600.0 }         // beats/sec (DSP)
    public var oscillationHz: Double { hz / 2.0 }               // oscillations/sec (display)
    public var nominalPeriodSeconds: Double { 1.0 / hz }
}

public struct MeasurementResult: Sendable {
    public let snappedRate: StandardBeatRate
    public let rateErrorSecondsPerDay: Double
    public let beatErrorMilliseconds: Double?
    public let amplitudeProxy: Double
    public let qualityScore: Double           // 0...1
    public let tickCount: Int
    public let tickTimings: [TickTiming]      // for timegraph display
}

public struct TickTiming: Sendable {
    public let beatIndex: Int
    public let residualMs: Double
    public let isEvenBeat: Bool
}
```

### Rate identification

The envelope FFT is the primary rate identification method:

1. Rectify the raw signal (absolute value) to demodulate the kHz carrier into positive bumps.
2. Lowpass at ~50 Hz via moving average to smooth the envelope.
3. Decimate to ~1 kHz to reduce FFT size.
4. Hann window + zero-pad to next power of two + FFT.
5. For each standard rate, measure peak magnitude in a ±0.5 Hz window around the beat frequency.

If the top rate has >30% margin over the runner-up, it is trusted directly. Otherwise, all rates are tried with full tick extraction and scored.

### Rate scoring (try-all-rates)

Each candidate rate is scored by: `recoveryRate × residualQuality × periodConsistency × (0.5 + 0.5 × envBoost)`

- **Recovery rate**: fraction of expected tick windows where a tick was found.
- **Residual quality**: how well tick times fit a linear regression (low residuals = high quality).
- **Period consistency**: how consistent the intervals between consecutive ticks are.
- **Envelope boost**: how strong this rate's FFT magnitude is relative to the maximum across all rates.

### Guided tick extraction

For a given candidate rate:

1. Divide the raw signal into beat-period-length windows.
2. Use a 20% window width centered on the expected tick position (empirically optimal — wider windows lose precision, narrower miss ticks).
3. Try 5 different phase offsets to avoid window boundary problems.
4. Within each window, find the energy peak (squared signal) as the tick location.
5. Use median alignment across detected ticks to refine the window positions.
6. Reject outliers using a 25% of period threshold (MAD-based rejection fails with beat error because residuals are bimodal).

### Linear regression and results

1. Assign integer beat indices to confirmed tick positions.
2. Linear regression: `time = slope × index + intercept`. Slope = measured beat period.
3. Rate error: `(nominalPeriod - measuredPeriod) / nominalPeriod × 86400` seconds/day. Positive = fast.
4. Beat error: separate ticks into even/odd indices, compute mean residual offset for each group, take the absolute difference. Report in milliseconds.
5. Quality score: derived from regression residual standard deviation, mapped to 0...1 via saturating function.

## 5. Error Budget

Sources of timing error, roughly ordered:

- **Sample quantization.** At 48 kHz, one sample is 20.8 microseconds. Parabolic interpolation reduces this to a small fraction of a sample, contributing roughly 2–5 microseconds per tick.
- **Template mismatch and noise.** Affects correlation peak sharpness. Mitigated by averaging and linear regression over many detected ticks.
- **iPhone clock drift.** Apple's mobile clocks are specified at roughly 20 ppm, equivalent to about 1.7 seconds/day. This is a systematic floor on absolute accuracy. It is below the typical precision of a mechanical watch (COSC chronometer spec is -4/+6 s/day) and therefore acceptable.
- **Regression over N ticks.** Random per-tick errors average down as 1/sqrt(N). With ~90 ticks in a 15-second 6 Hz capture and per-tick errors around 10 microseconds, the regression slope uncertainty is well below 1 microsecond per tick, or about 0.01 s/day.
- **Environmental noise.** Dominant real-world error source. Addressed by capture technique (press phone firmly to caseback, quiet environment) and by the quality score which warns when residuals are high.
- **Physical coupling sensitivity.** Even a few millimeters of position change on the caseback can dramatically affect signal strength, especially for quiet vintage movements. The real-time frequency bars help the user find the optimal contact point.

## 6. Synthetic Signal Generation

A synthetic tick generator is used for unit and integration testing. It produces audio buffers with known-correct ground truth, allowing pipeline verification without a physical watch.

### SyntheticTickGenerator specification

```swift
public struct SyntheticTickParameters {
    public let beatRate: StandardBeatRate
    public let durationSeconds: Double
    public let sampleRate: Double
    public let rateErrorSecondsPerDay: Double  // injected ground truth
    public let beatErrorMilliseconds: Double   // injected ground truth
    public let jitterStdMicroseconds: Double   // per-tick random timing noise
    public let snrDb: Double                   // signal-to-noise ratio
    public let tickShape: TickShape
    public let seed: UInt64                    // for reproducibility
}

public enum TickShape {
    case syntheticMechanical  // short exponentially-decaying burst ~5kHz, ~4ms
}
```

### Generation procedure

1. Compute the true period: `nominalPeriod × (1 - rateError/86400)`.
2. Generate ideal tick times at `[0, period, 2×period, ...]` up to duration.
3. Shift odd-indexed ticks by `beatError/2` and even-indexed by `-beatError/2`.
4. Add Gaussian jitter with specified standard deviation to each tick time.
5. Synthesize a tick waveform at each position (exponentially-decaying burst at ~5 kHz).
6. Add white Gaussian noise to achieve specified SNR.

## 7. Test Plan

### Unit tests

**SignalConditioner** — Bandpass rejects low frequencies, passes tick band. Envelope extraction preserves repetition structure. Decimation preserves signal energy.

**PeriodEstimator** — Correct rate identified at high SNR for all standard rates. Sub-bin frequency precision via parabolic interpolation. Low confidence on pure noise.

**TemplateBuilder** — Template correlates with original tick shape. Correct length for fold period. Handles non-divisible signal lengths.

**TickLocator** — Recovers tick times within 50 microseconds on clean synthetic signals. Correct tick count. Sub-sample interpolation improves over integer peaks.

**RateAnalyzer** — Rate error within 0.5 s/day of injected value at high SNR. Beat error within 0.2 ms of injected value. Quality score high for clean, low for noisy.

### Integration tests

For each standard rate, 15-second synthetic signal at high SNR with +5 s/day injected error. Acceptance: rate error within ±0.5 s/day, correct snapped rate, quality > 0.8.

Moderate SNR (20 dB): rate error within ±2 s/day.

Low SNR (10 dB): correct rate identified, rate error within ±5 s/day or quality < 0.5.

Dropout robustness: 20% and 40% missing ticks — pipeline should degrade gracefully.

## 8. iOS Integration Layer

### AudioCaptureService

Wraps `AVAudioEngine` with a `RollingCollector` actor maintaining a 60-second circular buffer at 48 kHz. Configures `AVAudioSession` with:
- Category: `.record`
- Mode: `.measurement` (disables AGC, noise suppression, voice processing)
- Input: built-in mic, bottom data source, omnidirectional polar pattern
- Input gain: maximum (1.0)

Provides `getRecentAudio(duration:)` to extract the most recent N seconds for rolling analysis. Cleans up AVAudioEngine in deinit to prevent mic leaks.

### FrequencyMonitor

Real-time envelope FFT visualization. Maintains a 5-second rolling buffer, analyzes ~4 times per second. During monitoring, runs its own AVAudioEngine. During recording, switches to external feed from AudioCaptureService (buffer preserved for seamless transition). Cleans up AVAudioEngine in deinit to prevent mic leaks.

Publishes power at each standard rate for the frequency bar display, allowing users to see which rate is dominant before and during recording. Uses a narrow ±0.2 Hz FFT search window to prevent visual overlap between adjacent beat rates (the closest pair, 5.0 Hz and 5.5 Hz, are only 0.5 Hz apart). Note: the measurement pipeline intentionally uses a wider ±0.5 Hz window so adjacent rates score similarly, triggering the more thorough try-all-rates validation path.

### MeasurementCoordinator

State machine: idle → monitoring → recording → result/error. `MeasurementConstants` enum centralizes shared thresholds (quality percentages, timing windows, quality color logic).

- **Monitoring**: FrequencyMonitor runs, frequency bars show real-time rates. `needsSweep` flag controls whether the balance wheel animates from 11:00→12:00 (first session only) or starts at 12:00 (subsequent sessions).
- **Recording**: AudioCaptureService captures continuously. Analysis runs every 3 seconds on most recent 15-second window. Tracks both current and best quality. Auto-stops at 80% quality. 60-second timeout. Results rejected if rate error exceeds ±999 s/day (industry-standard sanity check — anything beyond this is a measurement error, not a real watch rate).
- **Result**: Shown if best quality >= 30% and rate is physically plausible. Otherwise "try again" with tips.
- **Lifecycle**: `handleBackgrounded()` stops audio when the app enters the background, releasing the microphone.

### SwiftUI Views

- **ContentView**: Top-level state switch plus all screen views (IdleScreen, MonitoringScreen, RecordingScreen, AnalyzingScreen, ResultScreen, ErrorScreen). Uses `ScreenLayout` generic view for consistent stack-based adaptive layout: title at top, flexible logo area, text/bars zone, fixed-height bottom control zone so buttons stay in the same position across screens. `WatchLogo` always renders the same view hierarchy (wheel + hand + marker) with opacity toggles to prevent layout differences between screens. Observes `scenePhase` to release the mic when backgrounded. TimelineView(.animation) for 60fps recording animation.
- **FrequencyBarsView**: Bar chart visualization of power at each standard beat rate. Includes `formatOscHz` utility. VoiceOver accessible.
- **ResultViews**: Rate dial (±120 s/day range, blue=fast, red=slow, with beat error label: GOOD/FAIR/HIGH), timegraph (golden-ratio aspect), quality badge, GMT hand and marker views. All have VoiceOver accessibility labels.

## 9. Package Structure

```
WatchBeatCore/                      (Swift Package, no iOS dependencies)
    Package.swift
    Sources/
        WatchBeatCore/
            AudioBuffer.swift
            StandardBeatRate.swift
            SignalConditioner.swift
            PeriodEstimator.swift
            PeriodEstimate.swift
            TemplateBuilder.swift
            TickTemplate.swift
            TickLocator.swift
            RateAnalyzer.swift
            MeasurementPipeline.swift
            MeasurementResult.swift
            SyntheticTickGenerator.swift
            WAVReader.swift
        AnalyzeSamples/
            main.swift              (CLI tool for offline WAV analysis)
    Tests/
        WatchBeatCoreTests/
            SignalConditionerTests.swift
            PeriodEstimatorTests.swift
            TemplateBuilderTests.swift
            TickLocatorTests.swift
            RateAnalyzerTests.swift
            StandardBeatRateTests.swift
            PipelineIntegrationTests.swift
            SyntheticGeneratorTests.swift
            RealSampleTests.swift

WatchBeat/                          (Xcode project, depends on WatchBeatCore)
    WatchBeat/
        WatchBeatApp.swift
        ContentView.swift
        MeasurementCoordinator.swift
        AudioCaptureService.swift
        FrequencyMonitor.swift
        FrequencyBarsView.swift
        ResultViews.swift
        Info.plist
        Assets.xcassets/
```

## 10. Open Questions and Future Work

- **Positional analysis.** Measuring in multiple positions (dial up, crown down, etc.) and comparing results.
- **Session history.** Tracking rate over time to monitor regulation drift.
- **Amplitude estimation.** Lift angle calibration for amplitude in degrees.
- **Capture duration optimization.** Adaptive analysis interval — stop sooner when signal is strong.
- **Reference clock characterization.** Characterize iPhone clock drift against NTP for absolute accuracy below 1 s/day.
