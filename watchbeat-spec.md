# WatchBeat: Technical Specification

## 1. Goals and Non-Goals

### Goals

- Measure the rate error of a running mechanical or quartz wristwatch from a short (10–30 second) microphone recording taken by pressing an iPhone against the watch.
- Report rate error in seconds per day, relative to the nearest standard beat rate.
- Auto-detect the nominal beat rate from the set of standard values.
- Report secondary diagnostics: beat error (tick/tock asymmetry), amplitude proxy, and a measurement quality indicator.
- Target precision: ±1 second/day on a clean 28800 bph signal over a 30-second capture.
- Support single-shot capture-then-analyze in v1, with an architecture that refactors cleanly to real-time display later.

### Non-Goals (for v1)

- Full watch health diagnosis beyond a simple quality/jitter metric.
- Lift angle estimation or precise amplitude measurement in degrees.
- Positional analysis (dial up, crown down, etc.).
- Rate tracking over long periods or across multiple sessions.
- Support for non-standard beat rates outside the enumerated set.

## 2. Design Philosophy

**Separation of concerns.** The DSP pipeline has no knowledge of iOS, AVFoundation, UI, or audio capture. It operates on plain `[Float]` buffers with a known sample rate. The iOS integration layer is thin and does only what requires platform APIs: microphone access and buffer delivery.

**Testability first.** Every DSP component is a pure function of its inputs where possible. The synthetic signal generator is a first-class component, not an afterthought. Tests run on macOS via `swift test` without a simulator or device.

**Package boundary as enforcement.** The DSP core lives in a standalone Swift Package that does not depend on AVFoundation, UIKit, or any iOS-specific framework. This makes the separation structural rather than conventional — violations fail to compile.

**Single-shot first, real-time ready.** All DSP functions take complete signal buffers and return results. The pipeline is stateless from the caller's perspective. Real-time mode is a future refactor that feeds sliding windows into the same functions; no component is designed in a way that precludes this.

**Precision lives in the right place.** Period estimation uses a decimated envelope because it only needs to find a repetition rate. Tick localization uses the full-rate raw signal because that is where sub-sample precision comes from. Each stage uses the representation best suited to its job.

## 3. Signal Model

### Beat rates

The app recognizes the following standard beat rates, expressed in both beats per hour (bph) and beat frequency (Hz):

| bph    | Hz  | Notes                                          |
|--------|-----|------------------------------------------------|
| 3600   | 1   | Quartz watches (stepper motor pulse)           |
| 14400  | 4   | Half-speed mechanical, ticks on quarter second |
| 18000  | 5   | Vintage mechanical                             |
| 21600  | 6   | Common vintage/modern mechanical               |
| 25200  | 7   | Less common                                    |
| 28800  | 8   | Most common modern mechanical                  |
| 36000  | 10  | High-beat mechanical                           |

Detected rate is always snapped to the nearest value in this set. Rate error is reported as the deviation of the measured period from the nominal period of the snapped rate, converted to seconds per day.

### Tick structure (mechanical)

A single mechanical watch "tick" is a compound acoustic event from the escapement with three distinguishable sub-events (unlock, impulse, drop) spanning approximately 3–5 ms. The acoustic energy is concentrated roughly in the 3–8 kHz band, though this varies by movement. The balance wheel oscillates in two directions, and the acoustic signature of the two half-cycles ("tick" and "tock") is not identical. The asymmetry between them is the physical basis of beat error.

### Tick structure (quartz)

A quartz watch's visible seconds hand is driven by a stepper motor pulsing once per second. The acoustic signature is a single soft electromechanical click, generally lower in frequency and quieter than a mechanical escapement. No tick/tock asymmetry exists, so beat error is not meaningful for quartz.

### Precision target

Targeting ±1 second/day on a 28800 bph signal means resolving the period to about 1 part in 86400. At 48 kHz sampling, one sample is about 21 microseconds, and the nominal tick period at 8 Hz is 6000 samples. Sub-sample precision via interpolation of cross-correlation peaks, combined with linear regression over ~240 ticks in a 30-second capture, comfortably reaches this target on clean signals.

## 4. Pipeline Architecture

### Component overview

```
AudioCapture          [iOS layer, AVAudioEngine]
    |
    v
  Float buffer + sample rate
    |
    v
SignalConditioner     bandpass + envelope + decimate
    |
    v
PeriodEstimator       FFT-based period detection, snap to standard rate
    |
    v
TemplateBuilder       fold raw signal at 2x period, build tick-pair template
    |
    v
TickLocator           cross-correlate template against raw signal,
                      return sub-sample tick times
    |
    v
RateAnalyzer          linear regression + beat error + quality metrics
    |
    v
MeasurementResult
```

### Data types

```swift
public struct AudioBuffer {
    public let samples: [Float]
    public let sampleRate: Double
}

public enum StandardBeatRate: Int, CaseIterable {
    case bph3600 = 3600
    case bph14400 = 14400
    case bph18000 = 18000
    case bph21600 = 21600
    case bph25200 = 25200
    case bph28800 = 28800
    case bph36000 = 36000

    public var hz: Double { Double(rawValue) / 3600.0 }
    public var nominalPeriodSeconds: Double { 1.0 / hz }
}

public struct PeriodEstimate {
    public let measuredHz: Double
    public let snappedRate: StandardBeatRate
    public let confidence: Double  // 0...1, from FFT peak prominence
}

public struct TickTemplate {
    public let samples: [Float]
    public let sampleRate: Double
    public let spansBeats: Int  // 2 for mechanical, 1 for quartz
}

public struct MeasurementResult {
    public let snappedRate: StandardBeatRate
    public let rateErrorSecondsPerDay: Double
    public let beatErrorMilliseconds: Double?  // nil for quartz
    public let amplitudeProxy: Double
    public let qualityScore: Double  // 0...1, from regression residuals
    public let tickCount: Int
}
```

### Component responsibilities

**SignalConditioner** takes a raw audio buffer and produces a decimated envelope suitable for period estimation, plus passes through the raw buffer unchanged for downstream use. Bandpass filtering removes low-frequency rumble and high-frequency hiss. Envelope extraction (rectify + lowpass, or Hilbert magnitude) collapses the carrier and leaves the repetition structure. Decimation to around 1 kHz reduces the FFT length for stage 2 without losing any information in the 1–10 Hz range of interest.

**PeriodEstimator** takes the decimated envelope and returns the estimated beat frequency, the nearest standard rate, and a confidence score. Uses FFT of the envelope, searches for the largest peak within the 0.8–11 Hz band, applies parabolic interpolation around the peak bin for sub-bin frequency resolution, and snaps to the nearest standard rate. Confidence is derived from the ratio of peak magnitude to the median magnitude in the search band.

**TemplateBuilder** takes the raw (full-rate) signal and the estimated period, and produces a tick-pair template. For mechanical rates, folds the signal at 2× the period to capture both tick and tock in one template. For quartz (1 Hz), folds at 1× the period. The fold averages many tick instances into a denoised template.

**TickLocator** cross-correlates the template against the raw signal and returns an array of tick times in seconds, with sub-sample precision via parabolic interpolation of correlation peaks. Returns both the coarse peak indices and the interpolated times.

**RateAnalyzer** performs linear regression on tick index vs. tick time. The slope is the measured period; its deviation from the nominal period of the snapped rate gives the rate error, converted to seconds per day. Residuals from the regression give a quality score. For mechanical rates, the offset between odd-indexed and even-indexed ticks from their ideal regular positions gives the beat error. Amplitude proxy is computed from the peak cross-correlation magnitude averaged across detected ticks.

## 5. Algorithm Details

### Stage 1: Signal conditioning

1. Bandpass filter the raw signal. A 4th-order Butterworth bandpass from 1 kHz to 10 kHz is a reasonable default; the escapement energy for most movements falls within this band. Implemented via `vDSP_biquad` with cascaded second-order sections.
2. Extract the envelope. Full-wave rectify (absolute value) followed by a lowpass filter at ~50 Hz. Alternatively, Hilbert transform via FFT and take the magnitude. Rectify-and-lowpass is simpler and sufficient.
3. Decimate the envelope to approximately 1 kHz. Use `vDSP_desamp` with an appropriate anti-alias filter. The exact target rate is chosen so that an integer decimation factor produces a rate well above 20 Hz (Nyquist for 10 Hz signal).

The raw buffer is retained unchanged for stages 3 and 4. Only stages 1 and 2 operate on the decimated envelope.

### Stage 2: Period estimation

1. Window the decimated envelope with a Hann window to reduce spectral leakage.
2. Zero-pad to the next power of two for FFT efficiency. For a 30-second capture at 1 kHz envelope rate, this is 32768 samples.
3. Compute the real FFT via `vDSP_fft_zrip`.
4. Compute the magnitude spectrum.
5. Find the maximum magnitude bin within the search range corresponding to 0.8–11 Hz.
6. Apply parabolic interpolation around the peak bin using the three surrounding magnitudes to refine the frequency estimate.
7. Snap the interpolated frequency to the nearest value in `StandardBeatRate`.
8. Compute confidence as `peak_magnitude / median_magnitude_in_search_band`, normalized to 0...1 via a saturating function.

### Stage 3: Template construction

1. Determine the fold period in samples: `foldSamples = round(beatsPerTemplate * sampleRate / measuredHz)` where `beatsPerTemplate` is 2 for mechanical rates and 1 for quartz.
2. Reshape the raw signal into a matrix of shape `(numFolds, foldSamples)`, discarding any leftover samples at the end.
3. Average across the fold dimension to produce the template.
4. Normalize the template to unit energy.

The resulting template has the length of one tick pair (for mechanical) and represents the "average" acoustic signature of that pair across the capture.

### Stage 4: Tick localization

1. Cross-correlate the template against the raw signal using `vDSP_conv` (time domain, since the template is short). For longer templates, FFT-based correlation via overlap-save is an alternative.
2. Find local maxima in the correlation output that are separated by approximately the expected tick period (not the tick-pair period), with a tolerance window.
3. For each detected maximum, apply parabolic interpolation on the three surrounding correlation values to get a sub-sample peak location.
4. Convert peak sample indices to times in seconds.

Note on tick vs. tick-pair spacing: the template spans two beats, but we still want to locate every individual beat. The correlation output will have peaks at every beat position because each beat matches part of the template strongly. We search at beat-period spacing and use the correlation magnitude to index into tick/tock classification.

### Stage 5: Rate analysis

1. Build an index array `[0, 1, 2, ..., N-1]` and a corresponding tick time array.
2. Perform linear regression: `time = slope * index + intercept`. The slope is the measured beat period in seconds.
3. Rate error in seconds per day:
   `rateError = (nominalPeriod - measuredPeriod) / nominalPeriod * 86400`
   with sign indicating fast (positive) or slow (negative).
4. Regression residuals: compute the standard deviation of `time[i] - (slope*i + intercept)`. A clean watch produces residuals well under 1 ms; increasing residuals indicate jitter or measurement noise. Convert to a 0...1 quality score via a saturating function.
5. Beat error (mechanical only): separate ticks into odd and even indices, compute the mean offset of each subset from the regression line, and take the absolute difference. Report in milliseconds.
6. Amplitude proxy: mean of the peak correlation magnitudes at detected tick locations. This is not a calibrated amplitude in degrees but serves as a relative indicator.

## 6. Error Budget

Sources of timing error, roughly ordered:

- **Sample quantization.** At 48 kHz, one sample is 20.8 microseconds. Parabolic interpolation reduces this to a small fraction of a sample, contributing roughly 2–5 microseconds per tick.
- **Template mismatch and noise.** Affects correlation peak sharpness. Mitigated by averaging the template over many ticks and by linear regression over many detected ticks.
- **iPhone clock drift.** Apple's mobile clocks are specified at roughly 20 ppm, equivalent to about 1.7 seconds/day. This is a systematic floor on absolute accuracy that no amount of signal processing can remove. It is below the typical precision of a mechanical watch (COSC chronometer spec is -4/+6 s/day) and therefore acceptable.
- **Regression over N ticks.** Random per-tick errors average down as 1/sqrt(N). With ~240 ticks in a 30-second 8 Hz capture and per-tick errors around 10 microseconds, the regression slope uncertainty is well below 1 microsecond per tick, or about 0.01 s/day.
- **Environmental noise.** Dominant real-world error source. Addressed by capture technique (press phone firmly to watch, quiet environment) and by the quality score, which warns the user when residuals are high.

The combination of these sources puts the noise-floor precision well below the 1 s/day target on clean captures. Real-world precision will be limited by environmental noise and user technique.

## 7. Synthetic Signal Generation

A synthetic tick generator is required for unit and integration testing. It produces audio buffers with known-correct ground truth, allowing pipeline verification without a physical watch.

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
    public let tickShape: TickShape            // see below
    public let seed: UInt64                    // for reproducibility
}

public enum TickShape {
    case syntheticMechanical  // short exponentially-decaying burst
    case syntheticQuartz      // softer, lower-frequency click
    case recordedSample(URL)  // future: use a recorded template
}
```

### Generation procedure

1. Compute the true period in seconds: `nominalPeriod * (1 - rateError/86400)`.
2. Generate ideal tick times at `[0, period, 2*period, ...]` up to duration.
3. For mechanical rates, shift odd-indexed ticks by `beatError/2` and even-indexed ticks by `-beatError/2` (or vice versa).
4. Add Gaussian jitter with the specified standard deviation to each tick time.
5. For each tick time, synthesize a tick waveform at that position in the output buffer. The mechanical tick shape is a short exponentially-decaying burst centered around 5 kHz, roughly 4 ms long. The quartz tick shape is a softer, lower-frequency click.
6. Add white Gaussian noise to achieve the specified SNR.
7. Return the resulting buffer.

### Test coverage across beat rates

The test suite generates reference signals at every value in `StandardBeatRate`, at multiple SNR levels (clean, moderate, noisy), with injected rate errors of known magnitude and sign. Acceptance criteria are defined relative to each case.

## 8. Test Plan

### Unit tests

**SignalConditioner**
- Bandpass filter rejects a 100 Hz tone and passes a 5 kHz tone.
- Envelope of a 5 kHz tone modulated at 8 Hz has a clear 8 Hz component.
- Decimation preserves signal energy in the target band.

**PeriodEstimator**
- Given a synthetic 28800 bph signal at high SNR, returns `bph28800` with confidence > 0.9.
- Given signals at each standard rate, returns the correct snapped rate.
- Given a signal at 8.05 Hz (slightly fast 28800), returns `bph28800` and measuredHz within 0.01 Hz of 8.05.
- Given pure noise, returns low confidence.

**TemplateBuilder**
- Given a synthetic signal with a known tick shape, produced template correlates strongly with the original tick shape.
- Template length matches expected fold period within rounding tolerance.
- Handles signals not evenly divisible by fold period without crashing.

**TickLocator**
- Given a clean synthetic signal with known tick times, recovers tick times to within 50 microseconds.
- Tick count matches expected count within ±1.
- Sub-sample interpolation improves precision vs. integer peak indices on a synthetic test.

**RateAnalyzer**
- Given known-error synthetic signals, recovered rate error is within 0.5 s/day of injected value (at high SNR, 30-second duration).
- Given a signal with injected beat error of 2 ms, recovered beat error is within 0.2 ms.
- Quality score is high for clean signals, low for noisy signals.

### Integration tests

For each standard beat rate, generate a 30-second synthetic signal at high SNR with injected rate error of +5 s/day and run the full pipeline. Acceptance: recovered rate error within ±0.5 s/day of +5, correct snapped rate, quality score > 0.8.

Repeat with moderate SNR (20 dB). Acceptance: recovered rate error within ±2 s/day.

Repeat with low SNR (10 dB). Acceptance: correct snapped rate identified, rate error within ±5 s/day or quality score below 0.5 (warning the user).

### Real-world tests (manual)

Once the pipeline passes synthetic tests, measure one or more real watches with known reference rates (for example, a watch recently regulated on a commercial timing machine) and verify agreement within a few seconds per day. These tests are documented but not part of the automated suite.

## 9. iOS Integration Layer

The iOS layer is intentionally thin. It consists of:

- **AudioCaptureService** — wraps `AVAudioEngine`, configures `AVAudioSession` with category `.record` and mode `.measurement` to disable automatic gain control, noise suppression, and other voice-processing DSP. Installs an input tap, accumulates buffers into a single `[Float]` array for the requested duration, and hands it to the DSP pipeline as an `AudioBuffer`.
- **MeasurementCoordinator** — orchestrates "press button, record for N seconds, show result". Owns the session lifecycle and calls into the DSP package.
- **SwiftUI views** — capture button, progress indicator during recording, result display. Not part of this spec beyond noting they exist.

`AVAudioSession` configuration is critical. The default voice-processing modes destroy transients and will corrupt the signal. Measurement mode is mandatory.

## 10. Package Structure

```
WatchBeatCore/                    (Swift Package, no iOS dependencies)
    Package.swift
    Sources/
        WatchBeatCore/
            AudioBuffer.swift
            StandardBeatRate.swift
            SignalConditioner.swift
            PeriodEstimator.swift
            TemplateBuilder.swift
            TickLocator.swift
            RateAnalyzer.swift
            MeasurementPipeline.swift
            SyntheticTickGenerator.swift
    Tests/
        WatchBeatCoreTests/
            SignalConditionerTests.swift
            PeriodEstimatorTests.swift
            TemplateBuilderTests.swift
            TickLocatorTests.swift
            RateAnalyzerTests.swift
            PipelineIntegrationTests.swift
            SyntheticGeneratorTests.swift

WatchBeat/                     (Xcode project, depends on WatchBeatCore)
    AudioCaptureService.swift
    MeasurementCoordinator.swift
    Views/
        ...
```

`WatchBeatCore` declares no dependency on AVFoundation, UIKit, or any iOS framework. It depends only on `Accelerate` (for vDSP) and `Foundation`. It builds and tests on macOS via `swift test` without any simulator.

## 11. Open Questions and Future Work

- **Health metrics beyond quality score.** Full diagnosis (amplitude in degrees, lift angle calibration, positional variation) requires either a user-supplied lift angle value or a calibration procedure. Deferred.
- **Real-time refactor.** Once single-shot works well, the pipeline can be driven with sliding windows. `PeriodEstimator` and `TemplateBuilder` run once on initial data and are then locked; `TickLocator` and `RateAnalyzer` update continuously as new samples arrive. The current component design supports this without restructuring.
- **Quartz handling refinements.** The 1 Hz case may benefit from a different bandpass range (quartz stepper pulses are lower in frequency than escapement ticks) and possibly a separate tick template. Worth revisiting after initial quartz tests.
- **Bandpass parameter auto-tuning.** Different movements have different dominant frequency bands. Auto-selecting the bandpass based on observed spectral content could improve robustness across a wide range of watches.
- **Capture duration trade-off.** 30 seconds is a starting point. Longer captures improve precision as 1/sqrt(N); shorter captures are more convenient. A live quality indicator during real-time mode could let the user stop as soon as precision is adequate.
- **Reference clock characterization.** For users who care, the iPhone's own clock drift could be characterized against a network time reference and subtracted. This is overkill for v1 but worth noting.
