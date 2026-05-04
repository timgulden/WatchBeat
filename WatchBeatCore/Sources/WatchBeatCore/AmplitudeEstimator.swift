import Foundation
import Accelerate

/// Pulse width measurements from the escapement sounds, independent of lift angle.
/// The lift angle is only needed for the final amplitude formula, which is trivial
/// and can be computed in the UI layer.
public struct PulseWidthEstimate: Sendable, Equatable {
    /// Tick (even beat) pulse width in milliseconds.
    public let tickPulseMs: Double?
    /// Tock (odd beat) pulse width in milliseconds.
    public let tockPulseMs: Double?
    /// Number of folds used to build the averaged waveform.
    public let foldCount: Int
}

/// Estimates balance wheel amplitude from the pulse width of escapement sounds.
///
/// The pulse width corresponds to the time the balance wheel takes to traverse
/// the lift angle near its equilibrium position. At higher amplitudes the balance
/// moves faster, producing a shorter pulse.
///
/// Algorithm:
/// 1. High-pass filter at 1 kHz to remove low-frequency noise that smears
///    the pulse edges. Low frequencies can't change fast enough to encode
///    the sub-millisecond escapement structure.
/// 2. Rectify and fold at 2× beat period, phase-aligned to confirmed ticks.
/// 3. Smooth (3ms moving average) and measure pulse width at 20% of peak.
///
/// The amplitude formula (applied separately):
///   A = L / (2 × sin(π × t_pulse / T_beat))
///
/// Reference: vacaboja/tg open-source timegrapher
/// (https://github.com/vacaboja/tg, src/algo.c:745).
///
/// This is a *variant* of vacaboja's approach, not a direct port. Key
/// differences (see also TickAnatomy's `vacabojaAmplitude` for a faithful
/// port used for comparison):
///   - vacaboja smooths with a 1 ms leaky peak-hold + 1 ms box-mean; we use
///     a 3 ms arithmetic mean of rectified samples. The 3 ms mean broadens
///     pulses materially vs. vacaboja's 1 ms peak-hold.
///   - vacaboja sweeps the threshold upward from a noise-based floor until
///     both tick and tock amplitudes fall in [135°, 360°] with |Δ| < 60°;
///     we use a fixed threshold. The default is 0.30 (validated against
///     the SeagullStudy 2026-05-04 paired with a $150 timegrapher: at
///     0.30 the cluster reads 240° vs. TG 236°, within combined
///     uncertainty). On Swiss multi-event escapements, 0.30 sits above
///     the lock/drop flank peaks and reads the impulse-only width — the
///     physically meaningful quantity for the amplitude formula. At 0.20
///     the flanks are captured too, broadening the pulse and reading
///     amplitude ~50° low. WATCHBEAT_PULSE_THRESHOLD env var overrides
///     for tuning.
///   - vacaboja measures pulse width as the sample distance from the first
///     rising envelope peak (unlock) back to the lock anchor; we measure
///     full-width at the threshold.
public struct AmplitudeEstimator {

    private let conditioner = SignalConditioner()

    public init() {}

    /// Measure escapement pulse widths from a raw audio recording.
    ///
    /// - Parameters:
    ///   - input: Raw audio signal.
    ///   - rate: The detected beat rate.
    ///   - rateErrorSecondsPerDay: Measured rate error from regression.
    ///   - tickTimings: Confirmed tick timings from the measurement pipeline.
    /// - Returns: Pulse width estimates for tick and tock.
    public func measurePulseWidths(
        input: AudioBuffer,
        rate: StandardBeatRate,
        rateErrorSecondsPerDay: Double,
        tickTimings: [TickTiming]
    ) -> PulseWidthEstimate {
        let samples = input.samples
        let sampleRate = input.sampleRate
        let n = samples.count

        let beatPeriod = rate.nominalPeriodSeconds * (1.0 - rateErrorSecondsPerDay / 86400.0)
        let periodSamples = Int(round(beatPeriod * sampleRate))

        guard periodSamples > 100 && periodSamples < n / 3 && tickTimings.count >= 10 else {
            return PulseWidthEstimate(tickPulseMs: nil, tockPulseMs: nil, foldCount: 0)
        }

        // Step 1: High-pass filter at 1 kHz
        let filtered = conditioner.bandpassFilter(
            samples, sampleRate: sampleRate,
            lowCutoff: 1000, highCutoff: min(sampleRate / 2 - 100, 20000)
        )

        // Step 2: Rectify
        var rectified = [Float](repeating: 0, count: n)
        vDSP_vabs(filtered, 1, &rectified, 1, vDSP_Length(n))

        // Step 3: Light smooth for tick position finding (1ms)
        let posSmoothSamp = max(3, Int(0.001 * sampleRate))
        let posSignal = movingAverage(rectified, windowSize: posSmoothSamp)
        let sN = posSignal.count
        let halfSmooth = posSmoothSamp / 2

        // Calibrate sample offset from first few periods
        let searchEnd = min(periodSamples * 3, sN)
        var calibPeak = 0
        var calibVal: Float = 0
        for i in 0..<searchEnd {
            if posSignal[i] > calibVal { calibVal = posSignal[i]; calibPeak = i }
        }
        let estimatedBeatAtCalib = Double(calibPeak) / (beatPeriod * sampleRate)
        let nearestBeat = Int(round(estimatedBeatAtCalib))
        let sampleOffset = Double(calibPeak) - beatPeriod * sampleRate * Double(nearestBeat)

        // Step 4: Phase-aligned fold at 2× period (tick+tock pair)
        let halfPeriod = periodSamples / 2
        let foldLen = periodSamples * 2
        var folded = [Float](repeating: 0, count: foldLen)
        var foldCount = 0

        let evenTimings = tickTimings.filter { $0.isEvenBeat }
        for timing in evenTimings {
            let expected = Int(beatPeriod * sampleRate * Double(timing.beatIndex) + sampleOffset) - halfSmooth
            let lo = max(0, expected - periodSamples / 4)
            let hi = min(sN - 1, expected + periodSamples / 4)
            guard lo < hi else { continue }

            var peakIdx = lo
            var peakVal: Float = posSignal[lo]
            for j in (lo + 1)...hi {
                if posSignal[j] > peakVal { peakVal = posSignal[j]; peakIdx = j }
            }

            let foldStart = peakIdx - halfPeriod
            guard foldStart >= 0 && foldStart + foldLen < n else { continue }
            for i in 0..<foldLen { folded[i] += rectified[foldStart + i] }
            foldCount += 1
        }

        guard foldCount >= 3 else {
            return PulseWidthEstimate(tickPulseMs: nil, tockPulseMs: nil, foldCount: foldCount)
        }

        let div = Float(foldCount)
        for i in 0..<foldLen { folded[i] /= div }

        // Step 5: Two smoothings of the folded waveform.
        //   - 3 ms: stable main-peak localization and fallback pulse-width.
        //   - 0.15 ms (fine): preserves escapement sub-structure (unlock /
        //     impulse / drop) so we can recover the physically meaningful
        //     pulse even when 20%-threshold walks across it as one wide blob.
        let foldSmoothSamp = max(3, Int(0.003 * sampleRate))
        let smoothed = movingAverage(folded, windowSize: foldSmoothSamp)
        let fineSmoothSamp = max(3, Int(0.00015 * sampleRate))
        let fineSmoothed = movingAverage(folded, windowSize: fineSmoothSamp)
        let fN = smoothed.count
        guard fN > periodSamples else {
            return PulseWidthEstimate(tickPulseMs: nil, tockPulseMs: nil, foldCount: foldCount)
        }

        // Step 6: Find tick and tock peaks (on the stable 3ms smoothed fold)
        let tickPeak = findPeakNear(smoothed, target: halfPeriod, range: periodSamples / 3)
        let tockPeak = findPeakNear(smoothed, target: halfPeriod + periodSamples, range: periodSamples / 3)

        // Baseline = 10th percentile of the smoothed fold. Represents the
        // "between-events" noise floor. Used to make threshold relative to
        // (peak - baseline), so high-noise recordings (HVAC, room reverb)
        // don't have their apparent pulse widths smeared by the constant
        // background. On clean recordings baseline ≈ 0, and the calculation
        // collapses to "20% of peak" — the previous behavior.
        let sortedFold = smoothed.sorted()
        let baseline = sortedFold[sortedFold.count / 10]

        // Step 7: Measure pulse widths. Two strategies:
        //   A) 20% threshold above baseline on the 3ms-smoothed fold — works
        //      great for single-event ticks. Threshold rises with noise floor
        //      so a noisy recording's pulse isn't artificially widened.
        //   B) Phase-span on the 0.15ms-smoothed fold — detects up to 3
        //      prominent sub-peaks around the main peak and uses the span
        //      from first to last. Physically correct for multi-event ticks,
        //      but on a clean single-event tick it latches onto noise wiggles
        //      and reports 1-2 ms spans (way too narrow → amp > 360° bogus).
        // Neither dominates. Try threshold first; if it's missing or the
        // resulting span is implausibly wide (>25 ms, classic multi-event
        // smear), try phase-span.
        let tickPulseMs = bestPulseMs(peakIdx: tickPeak, fineSignal: fineSmoothed,
                                      coarseSignal: smoothed, searchRadius: periodSamples / 3,
                                      beatPeriod: beatPeriod, sampleRate: sampleRate,
                                      baseline: baseline)
        let tockPulseMs = bestPulseMs(peakIdx: tockPeak, fineSignal: fineSmoothed,
                                      coarseSignal: smoothed, searchRadius: periodSamples / 3,
                                      beatPeriod: beatPeriod, sampleRate: sampleRate,
                                      baseline: baseline)

        return PulseWidthEstimate(tickPulseMs: tickPulseMs, tockPulseMs: tockPulseMs, foldCount: foldCount)
    }

    // MARK: - Amplitude Formula

    /// Compute amplitude from pulse width, beat period, and lift angle.
    ///
    /// A = L / (2 × sin(π × t_pulse / T_beat))
    ///
    /// - Parameters:
    ///   - pulseMs: Pulse width in milliseconds.
    ///   - beatPeriodSeconds: Beat period in seconds.
    ///   - liftAngleDegrees: Lift angle of the movement in degrees.
    /// - Returns: Amplitude in degrees, or nil if out of plausible range (90-360°).
    public static func amplitude(
        pulseMs: Double, beatPeriodSeconds: Double, liftAngleDegrees: Double
    ) -> Double? {
        let pulseSeconds = pulseMs / 1000.0
        guard pulseSeconds > 0 && beatPeriodSeconds > 0 else { return nil }
        let ratio = pulseSeconds / beatPeriodSeconds
        guard ratio > 0.001 && ratio < 0.25 else { return nil }
        let sinVal = sin(Double.pi * ratio)
        guard sinVal > 1e-10 else { return nil }
        let a = liftAngleDegrees / (2.0 * sinVal)
        // Lower bound 90°: sick vintage pin-lever movements (Tim's Timex) can
        // legitimately run at 100-130° and still tick — vacaboja's 135° floor
        // was too tight for these. Below ~80° a watch usually stops, so 90° is
        // a safe minimum that admits "running but sick" without letting noise
        // through (a noise-driven wide pulse pushes ratio toward 0.25, which
        // corresponds to amplitude near the lift angle itself — well below 90).
        return (a >= 90 && a <= 360) ? a : nil
    }

    /// Compute combined amplitude from a pulse width estimate.
    ///
    /// Returns the average of tick and tock amplitudes if both are valid,
    /// or whichever one is valid, or nil.
    public static func combinedAmplitude(
        pulseWidths: PulseWidthEstimate, beatRate: StandardBeatRate,
        rateErrorSecondsPerDay: Double, liftAngleDegrees: Double
    ) -> Double? {
        let beatPeriod = beatRate.nominalPeriodSeconds * (1.0 - rateErrorSecondsPerDay / 86400.0)
        let tickAmp = pulseWidths.tickPulseMs.flatMap {
            amplitude(pulseMs: $0, beatPeriodSeconds: beatPeriod, liftAngleDegrees: liftAngleDegrees)
        }
        let tockAmp = pulseWidths.tockPulseMs.flatMap {
            amplitude(pulseMs: $0, beatPeriodSeconds: beatPeriod, liftAngleDegrees: liftAngleDegrees)
        }
        if let t = tickAmp, let k = tockAmp { return (t + k) / 2 }
        return tickAmp ?? tockAmp
    }

    // MARK: - Private Helpers

    /// Measure pulse width for one side (tick or tock). Prefer the 20%
    /// threshold width on the coarse fold; if that produces an implausibly
    /// wide pulse (> 25 ms, typical of multi-event tick smearing) fall back
    /// to phase-span detection on the fine fold.
    private func bestPulseMs(
        peakIdx: Int?, fineSignal: [Float], coarseSignal: [Float],
        searchRadius: Int, beatPeriod: Double, sampleRate: Double,
        baseline: Float
    ) -> Double? {
        guard let peak = peakIdx else { return nil }
        let halfLimit = beatPeriod / 2

        // Primary: threshold-based, with threshold relative to (peak - baseline).
        // Default 0.30 — chosen to read the impulse alone on Swiss multi-
        // event escapements (lock/impulse/drop sub-events: 0.30 sits above
        // the flank peaks). Validated against SeagullStudy 2026-05-04
        // (cluster reads 240° vs TG 236°). WATCHBEAT_PULSE_THRESHOLD env
        // var overrides for tuning.
        let thrEnv = ProcessInfo.processInfo.environment["WATCHBEAT_PULSE_THRESHOLD"]
        let thrFrac = Float(thrEnv ?? "") ?? 0.30
        let pwSec = measurePulseWidth(coarseSignal, peakIndex: peak, thresholdFraction: thrFrac,
                                      maxExtent: searchRadius, sampleRate: sampleRate,
                                      baseline: baseline)
        let thresholdMs: Double? = (pwSec > 0 && pwSec < halfLimit) ? pwSec * 1000 : nil

        // Threshold pulses narrower than 25 ms almost always correspond to
        // a single well-defined escapement event — trust them.
        if let ms = thresholdMs, ms < 25.0 {
            return ms
        }

        // Threshold pulse is either missing or suspiciously wide. Try
        // phase-span: find up to 3 prominent sub-peaks within ±searchRadius/2
        // of the main peak and measure the span from first to last.
        let phaseRadius = searchRadius / 2
        if let span = phaseSpanMs(fineSignal, around: peak, radius: phaseRadius, sampleRate: sampleRate),
           span > 0.5, span / 1000.0 < halfLimit {
            return span
        }

        // Neither method gave anything usable.
        return thresholdMs
    }

    /// Detect up to three prominent local peaks around a center index and
    /// return the span (in ms) from the first to last in time. Returns nil if
    /// fewer than two peaks pass prominence (≥12% of local max) and minimum
    /// separation (0.5 ms).
    private func phaseSpanMs(_ signal: [Float], around center: Int, radius: Int, sampleRate: Double) -> Double? {
        let n = signal.count
        let lo = max(2, center - radius)
        let hi = min(n - 3, center + radius)
        guard lo + 4 < hi else { return nil }

        var localMax: Float = 0
        for i in lo...hi { if signal[i] > localMax { localMax = signal[i] } }
        guard localMax > 0 else { return nil }
        let threshold = localMax * 0.12
        let minSepSamples = max(1, Int(0.0005 * sampleRate))

        // 5-point local maxima above prominence floor.
        var peaks: [(idx: Int, amp: Float)] = []
        for i in lo...hi {
            let v = signal[i]
            if v < threshold { continue }
            if v >= signal[i - 1] && v >= signal[i - 2] && v >= signal[i + 1] && v >= signal[i + 2] {
                peaks.append((i, v))
            }
        }
        guard !peaks.isEmpty else { return nil }

        // Greedy: keep tallest peaks that are min-sep from already-kept ones.
        peaks.sort { $0.amp > $1.amp }
        var kept: [(idx: Int, amp: Float)] = []
        for p in peaks {
            if kept.count >= 3 { break }
            if kept.allSatisfy({ abs($0.idx - p.idx) >= minSepSamples }) {
                kept.append(p)
            }
        }
        guard kept.count >= 2 else { return nil }

        kept.sort { $0.idx < $1.idx }
        let spanSamples = kept.last!.idx - kept.first!.idx
        return Double(spanSamples) / sampleRate * 1000.0
    }

    private func measurePulseWidth(
        _ signal: [Float], peakIndex: Int, thresholdFraction: Float,
        maxExtent: Int, sampleRate: Double, baseline: Float
    ) -> Double {
        let n = signal.count
        let peakVal = signal[peakIndex]
        guard peakVal > baseline else { return 0 }

        let thresh = baseline + thresholdFraction * (peakVal - baseline)
        let lo = max(0, peakIndex - maxExtent)
        let hi = min(n - 1, peakIndex + maxExtent)

        var lead = peakIndex
        while lead > lo && signal[lead] > thresh { lead -= 1 }
        var trail = peakIndex
        while trail < hi && signal[trail] > thresh { trail += 1 }

        return Double(trail - lead) / sampleRate
    }

    private func findPeakNear(_ signal: [Float], target: Int, range: Int) -> Int? {
        let n = signal.count
        let lo = max(0, target - range)
        let hi = min(n - 1, target + range)
        guard lo < hi else { return nil }
        var best = lo
        var bestVal: Float = signal[lo]
        for j in (lo + 1)...hi {
            if signal[j] > bestVal { bestVal = signal[j]; best = j }
        }
        return best
    }

    private func movingAverage(_ signal: [Float], windowSize: Int) -> [Float] {
        let n = signal.count
        guard windowSize > 1 && windowSize < n else { return signal }
        let outCount = n - windowSize + 1
        var result = [Float](repeating: 0, count: outCount)
        var sum: Float = 0
        for i in 0..<windowSize { sum += signal[i] }
        result[0] = sum / Float(windowSize)
        for i in 1..<outCount {
            sum += signal[i + windowSize - 1] - signal[i - 1]
            result[i] = sum / Float(windowSize)
        }
        return result
    }
}
