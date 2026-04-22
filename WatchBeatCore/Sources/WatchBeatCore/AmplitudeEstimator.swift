import Foundation
import Accelerate

/// Pulse width measurements from the escapement sounds, independent of lift angle.
/// The lift angle is only needed for the final amplitude formula, which is trivial
/// and can be computed in the UI layer.
public struct PulseWidthEstimate: Sendable {
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
///     we use a fixed 20% threshold. In vacaboja's algorithm, 20% is the
///     upper bound of the sweep, not the operating point.
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

        // Step 5: Smooth the folded waveform (3ms)
        let foldSmoothSamp = max(3, Int(0.003 * sampleRate))
        let smoothed = movingAverage(folded, windowSize: foldSmoothSamp)
        let fN = smoothed.count
        guard fN > periodSamples else {
            return PulseWidthEstimate(tickPulseMs: nil, tockPulseMs: nil, foldCount: foldCount)
        }

        // Step 6: Find tick and tock peaks
        let tickPeak = findPeakNear(smoothed, target: halfPeriod, range: periodSamples / 3)
        let tockPeak = findPeakNear(smoothed, target: halfPeriod + periodSamples, range: periodSamples / 3)

        // Step 7: Measure pulse widths at 20% of peak height
        let thresholdFraction: Float = 0.20
        let tickPulseMs: Double?
        let tockPulseMs: Double?

        if let tp = tickPeak {
            let pw = measurePulseWidth(smoothed, peakIndex: tp, thresholdFraction: thresholdFraction,
                                       maxExtent: periodSamples / 3, sampleRate: sampleRate)
            tickPulseMs = pw > 0 && pw < beatPeriod / 2 ? pw * 1000 : nil
        } else {
            tickPulseMs = nil
        }

        if let kp = tockPeak {
            let pw = measurePulseWidth(smoothed, peakIndex: kp, thresholdFraction: thresholdFraction,
                                       maxExtent: periodSamples / 3, sampleRate: sampleRate)
            tockPulseMs = pw > 0 && pw < beatPeriod / 2 ? pw * 1000 : nil
        } else {
            tockPulseMs = nil
        }

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
    /// - Returns: Amplitude in degrees, or nil if out of plausible range (135-360°).
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
        return (a >= 135 && a <= 360) ? a : nil
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

    private func measurePulseWidth(
        _ signal: [Float], peakIndex: Int, thresholdFraction: Float,
        maxExtent: Int, sampleRate: Double
    ) -> Double {
        let n = signal.count
        let peakVal = signal[peakIndex]
        guard peakVal > 0 else { return 0 }

        let thresh = thresholdFraction * peakVal
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
