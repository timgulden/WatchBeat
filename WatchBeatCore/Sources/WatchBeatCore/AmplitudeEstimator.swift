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
/// We measure sub-event spacing on a per-class folded envelope (the
/// vacaboja-style approach), not pulse-width-at-threshold. The per-class
/// fold is anchored on the picker's clean tick positions (no re-anchoring
/// via sample-offset calibration). Within each class fold:
///   1. Find the dominant peak — typically the LOCK click (loudest sound
///      in a tick), at the center of the fold.
///   2. Find the FARTHEST sub-event peak on each side of dominant within
///      ±25 ms, with valley-prominence ≥ 5% of dominant amplitude. The
///      farthest peak is the unlock (or drop) — the bound of the lift-
///      angle traversal.
///   3. Half-pulse = farthest-distance / 2 (or average of the two sides).
///      The factor of 2 reflects that distance from dominant to the far
///      end of traversal is the FULL traversal time, while the formula
///      A = L/(2·sin(π·t/T)) expects HALF the traversal time as `t`.
///
/// This works on both Swiss multi-event ticks and pin-lever ticks because
/// it measures sub-event spacing — a universal physical quantity — rather
/// than envelope widths that vary with tick acoustic structure. Validated
/// against SeagullStudy 2026-05-04 (cluster reads 241° vs TG 236°) and
/// Tim's pin-lever Timex (reads ~140° vs TG 140°).
public struct AmplitudeEstimator {

    /// SNR floor below which per-class fold amplitude readings are
    /// suppressed (formula returns nil → result page shows "---").
    /// SNR = peak / 10th-percentile-background within ±25 ms of the
    /// fold center. Tuned 2026-05-06 from Tim's airplane Seagull (SNR
    /// 2.0/2.5, would have read 95° vs ground-truth ~240°) vs clean
    /// TG-validated Seagulls (SNR 10.6+, read correctly). 5 sits in
    /// the gap.
    public static let minFoldSNR: Double = 5.0

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

        // Step 3: Build per-class folded waveforms anchored directly on the
        // picker's clean tick timings. The Reference picker has already done
        // the hard work of identifying real ticks (pure-argmax + heavy-
        // rejection re-anchor + outlier rejection); we just use those
        // anchors directly. No re-anchoring via sample-offset calibration —
        // that path was vulnerable to noise events near recording start.
        //
        // Each class (tick = even beat, tock = odd beat) gets its own fold
        // window of ±halfPeriod centered on each timing. Per-class folding
        // means tick and tock are analyzed independently — no cross-class
        // smearing if the BE is large.
        let halfPeriod = periodSamples / 2
        let foldLen = 2 * halfPeriod + 1
        var tickFold = [Float](repeating: 0, count: foldLen)
        var tockFold = [Float](repeating: 0, count: foldLen)
        var tickCount = 0
        var tockCount = 0

        // Re-anchor each fold on its OWN loudest sample within ±1.5 ms of
        // the picker's chosen position. The picker position is correct to
        // within a few hundred microseconds (it's the regression-line-
        // projected pick position with residual added); folding aligned on
        // that gives slightly smeared sub-event peaks because each beat's
        // loudest sample is ~0.5-1 ms offset. Re-anchoring tightens the
        // fold's main peak and sharpens the sub-event peaks correspondingly.
        let anchorRadius = max(1, Int(0.0015 * sampleRate))
        for timing in tickTimings {
            let center0 = Int(round(timing.timeSeconds * sampleRate))
            let aLo = max(0, center0 - anchorRadius)
            let aHi = min(n - 1, center0 + anchorRadius)
            var center = center0
            var bestVal: Float = rectified[max(0, min(n - 1, center0))]
            for j in aLo...aHi where rectified[j] > bestVal {
                bestVal = rectified[j]; center = j
            }
            let lo = center - halfPeriod
            let hi = center + halfPeriod
            guard lo >= 0 && hi < n else { continue }
            if timing.isEvenBeat {
                for i in 0..<foldLen { tickFold[i] += rectified[lo + i] }
                tickCount += 1
            } else {
                for i in 0..<foldLen { tockFold[i] += rectified[lo + i] }
                tockCount += 1
            }
        }

        guard tickCount >= 3 || tockCount >= 3 else {
            return PulseWidthEstimate(tickPulseMs: nil, tockPulseMs: nil, foldCount: tickCount + tockCount)
        }

        if tickCount > 0 { let inv = 1 / Float(tickCount); for i in 0..<foldLen { tickFold[i] *= inv } }
        if tockCount > 0 { let inv = 1 / Float(tockCount); for i in 0..<foldLen { tockFold[i] *= inv } }

        // Step 4: Smoothing — 0.7 ms — wide enough to suppress single-cycle
        // ripple but narrow enough to leave the lock/drop sub-events
        // distinct from the impulse. With 1.5+ ms smoothing the +3-5 ms
        // drop event on Seagulls merges into the impulse decay slope and
        // can't be detected by valley-prominence; 0.7 ms preserves it.
        let smoothSamp = max(3, Int(0.0007 * sampleRate))
        let tickSmoothed = movingAverage(tickFold, windowSize: smoothSamp)
        let tockSmoothed = movingAverage(tockFold, windowSize: smoothSamp)

        // Step 5: Sub-event spacing measurement.
        //
        // Vacaboja and commercial timegraphers measure the time between the
        // "lock" (or "unlock") sub-event and the dominant impulse peak. This
        // interval directly corresponds to the balance wheel traversing the
        // lift angle — physically what the formula A = L/(2·sin(π·t/T))
        // expects. Pulse-width-at-threshold (the previous approach) is a
        // proxy that happens to track sub-event spacing on Swiss multi-
        // event ticks but diverges substantially on pin-lever movements
        // (where the strike spike is brief but the lock-to-impulse gap is
        // 10-15 ms). The sub-event-spacing approach works the same on both
        // families — no per-rate or per-watch exception needed.
        //
        // Implementation: find the dominant peak (impulse, near the center
        // of the fold), then find the FARTHEST significant secondary peak
        // within ±25 ms. The farthest-peak rule is correct because:
        //   - Swiss watches: lock and drop sit ~5 ms either side of impulse;
        //     farthest is one of them, distance ~5 ms → matches TG.
        //   - Pin-lever: lock event is 10-15 ms before impulse, drop is
        //     close-in/masked; farthest is the lock, distance ~12 ms →
        //     matches TG.
        // Per-class SNR gate (threshold = AmplitudeEstimator.minFoldSNR).
        // Below the floor, suppress the pulse measurement entirely; the
        // result page renders "---" rather than a noise-inflated wrong
        // number. The threshold's tuning is documented on the constant
        // declaration.
        let tickSNR = amplitudeFoldSNR(tickSmoothed, sampleRate: sampleRate)
        let tockSNR = amplitudeFoldSNR(tockSmoothed, sampleRate: sampleRate)

        var tickPulseMs = subEventSpacingMs(tickSmoothed, sampleRate: sampleRate)
        var tockPulseMs = subEventSpacingMs(tockSmoothed, sampleRate: sampleRate)
        if tickSNR < Self.minFoldSNR { tickPulseMs = nil }
        if tockSNR < Self.minFoldSNR { tockPulseMs = nil }

        if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_AMP_SNR"] != nil {
            FileHandle.standardError.write(
                "[amp-snr] tick=\(tickSNR) tock=\(tockSNR) (threshold=\(Self.minFoldSNR))\n".data(using: .utf8)!)
        }

        // Diagnostic dump for tuning. Set WATCHBEAT_DUMP_FOLD=path/prefix
        // to write per-class-fold CSVs of the rectified+smoothed signal
        // around the impulse, suitable for plotting and inspection.
        if let dumpPath = ProcessInfo.processInfo.environment["WATCHBEAT_DUMP_FOLD"] {
            let dom = tickSmoothed.count / 2
            let half = Int(0.025 * sampleRate)
            let lo = max(0, dom - half), hi = min(tickSmoothed.count - 1, dom + half)
            var out = "ms,tick,tock\n"
            for i in lo...hi {
                let ms = Double(i - dom) / sampleRate * 1000.0
                out += "\(ms),\(tickSmoothed[i]),\(tockSmoothed[i])\n"
            }
            try? out.write(toFile: dumpPath, atomically: true, encoding: .utf8)
        }

        return PulseWidthEstimate(tickPulseMs: tickPulseMs, tockPulseMs: tockPulseMs,
                                  foldCount: max(tickCount, tockCount))
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

    /// Sub-event spacing measurement on a per-class folded envelope.
    ///
    /// The fold is anchored on each beat's true tick position so the
    /// dominant peak (impulse) lies at the center of the fold (index =
    /// foldLen/2). We find significant secondary peaks within ±25 ms of
    /// the dominant and return the distance to the FARTHEST one.
    ///
    /// Why farthest, not nearest: Swiss multi-event ticks have lock and
    /// drop both ~5 ms from impulse (so farthest ≈ nearest ≈ 5 ms, matches
    /// TG). Pin-lever ticks have a lock event ~10-15 ms before impulse and
    /// the drop event acoustically masked by the strike's ringing tail
    /// (so farthest ≈ lock distance, matches TG; nearest would catch the
    /// ringing wiggle and underestimate). Using the farthest gives the
    /// correct lock-to-impulse interval on both families.
    ///
    /// Returns nil if the envelope has no significant secondaries (very
    /// quiet recording, single-event tick with all energy in the spike,
    /// etc.) — the formula then falls back to the other class or
    /// suppresses amplitude entirely. Default behavior matches the TG:
    /// "we can't tell" is reported as "---", not as a wrong number.
    private func subEventSpacingMs(_ signal: [Float], sampleRate: Double) -> Double? {
        let n = signal.count
        guard n >= 8 else { return nil }
        let center = n / 2

        // Locate the dominant peak — should be near `center` since the fold
        // is anchored on the picker's tick position. Allow ±2 ms for slight
        // misregistration.
        let centerSlop = max(1, Int(0.002 * sampleRate))
        let dCo = max(2, center - centerSlop)
        let dHi = min(n - 3, center + centerSlop)
        guard dCo < dHi else { return nil }
        var domIdx = dCo
        var domVal: Float = signal[dCo]
        for i in (dCo + 1)...dHi {
            if signal[i] > domVal { domVal = signal[i]; domIdx = i }
        }
        guard domVal > 0 else { return nil }

        // Search radius ±25 ms — covers Swiss (sub-events at ~5 ms) and
        // pin-lever (~12 ms lock-to-impulse) without picking up next-beat
        // energy at half-period distance (~80-100 ms).
        let radiusSamples = Int(0.025 * sampleRate)
        let lo = max(2, domIdx - radiusSamples)
        let hi = min(n - 3, domIdx + radiusSamples)
        guard lo + 4 < hi else { return nil }

        // Min separation from dominant: 1.5 ms. Closer "peaks" are
        // ringing on top of the dominant, not real sub-events.
        let minSepFromDom = max(1, Int(0.0015 * sampleRate))
        // Prominence floor: 5% of dominant amplitude. A real sub-event
        // (lock, drop) typically reads 10-30% of the impulse on Swiss
        // ticks, ≥ 5% on pin-lever recordings (where the lock event is
        // a softer click before the strike). Below 5% it's envelope noise.
        let prominenceFloor: Float = 0.05 * domVal

        // For each candidate, require a TRUE VALLEY between the dominant
        // and the candidate. A real sub-event (lock or drop) is a peak
        // separated from the impulse by a clear local minimum; a spurious
        // ripple on the impulse's decay slope has no such valley.
        func valleyMin(from a: Int, to b: Int) -> Float {
            let lo = min(a, b), hi = max(a, b)
            var m = signal[lo]
            for i in lo...hi { if signal[i] < m { m = signal[i] } }
            return m
        }

        // Find the FARTHEST qualifying peak on each side of dominant.
        //
        // Why farthest, not most prominent: the dominant peak is typically
        // the LOCK click (sharpest, loudest). The far-side sub-events
        // (unlock and drop) sit at distances ≈ ±full-traversal-time. The
        // mid-side peak (impulse, mostly mechanical motion) sits at
        // ±half-traversal. For a Swiss watch at 240° amplitude, full
        // traversal is ~9.7 ms — the unlock peak sits at -9.7 ms (modest
        // prominence) and the impulse at -4.9 ms (often higher
        // prominence because of mechanical scraping). Picking the most
        // prominent peak would lock onto the impulse and read amplitude
        // ~30% low. Picking the farthest gets us to unlock, the actual
        // bound of lift-angle traversal.
        //
        // The formula A = L/(2·sin(π·t/T)) uses t = half-traversal. So
        // we report distance/2 from dominant to the farthest sub-event.
        var farthestBefore: Int = 0
        var farthestAfter: Int = 0
        for i in lo...hi {
            let dist = i - domIdx
            if abs(dist) < minSepFromDom { continue }
            let v = signal[i]
            if v < prominenceFloor { continue }
            guard v >= signal[i - 1] && v >= signal[i - 2]
                  && v >= signal[i + 1] && v >= signal[i + 2] else { continue }
            let valley = valleyMin(from: domIdx, to: i)
            let prominence = v - valley
            if prominence < prominenceFloor { continue }
            if dist < 0 {
                if -dist > farthestBefore { farthestBefore = -dist }
            } else {
                if dist > farthestAfter { farthestAfter = dist }
            }
        }

        // Use distance to farthest qualifying sub-event divided by 2 to get
        // half-traversal (the formula's expected `t`). If sub-events are
        // visible on both sides, average the half-traversals.
        let halfPulseSamples: Int
        if farthestBefore > 0 && farthestAfter > 0 {
            halfPulseSamples = (farthestBefore + farthestAfter) / 4
        } else if farthestBefore > 0 {
            halfPulseSamples = farthestBefore / 2
        } else if farthestAfter > 0 {
            halfPulseSamples = farthestAfter / 2
        } else {
            return nil
        }
        return Double(halfPulseSamples) / sampleRate * 1000.0
    }

    /// Per-class fold SNR: dominant peak amplitude divided by the 10th-
    /// percentile fold value within ±25 ms of the dominant peak. Used
    /// both as a diagnostic and (eventually) as a gate on whether to
    /// trust the amplitude reading.
    ///
    /// Clean recordings give SNR > ~20 (dominant peak well above the
    /// noise floor). Recordings with high ambient noise (e.g., airplane
    /// cabin) give SNR ~5-10 — the noise floor is high, the dominant
    /// peak isn't much above it, and the sub-event spacing measurement
    /// gets stretched because the click's "shoulders" stay above the
    /// (high) local floor longer than they should.
    private func amplitudeFoldSNR(_ signal: [Float], sampleRate: Double) -> Double {
        let n = signal.count
        guard n >= 8 else { return 0 }
        let center = n / 2
        let centerSlop = max(1, Int(0.002 * sampleRate))
        let dCo = max(0, center - centerSlop)
        let dHi = min(n - 1, center + centerSlop)
        guard dCo < dHi else { return 0 }
        var domVal: Float = signal[dCo]
        for i in (dCo + 1)...dHi where signal[i] > domVal { domVal = signal[i] }

        let radiusSamples = Int(0.025 * sampleRate)
        let lo = max(0, center - radiusSamples)
        let hi = min(n - 1, center + radiusSamples)
        guard lo < hi else { return 0 }

        var slice = Array(signal[lo...hi])
        slice.sort()
        let p10 = slice[max(0, slice.count / 10)]
        guard p10 > 0 else { return Double.greatestFiniteMagnitude }
        return Double(domVal) / Double(p10)
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
