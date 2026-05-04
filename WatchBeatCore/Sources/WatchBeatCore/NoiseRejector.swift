import Foundation

/// Two-pass time-domain noise rejection applied BEFORE the per-window
/// argmax pick in the Reference picker. Designed to defeat isolated loud
/// transients (chair scrapes, dropped objects, voice spikes) that would
/// otherwise win the argmax and bias the regression slope.
///
/// Given the FFT-anchored window centers and the smoothed signal:
///   1. Divide each window into N equal sub-boxes (default 10 → 20 ms
///      wide for a 200 ms beat at 18000 bph).
///   2. Pass 1: compute global noise floor as the mean of the bottom 70%
///      of all sub-box peak energies. Sub-boxes whose peak does not
///      exceed 2 × floor are marked "dead."
///   3. Pass 2: for each sub-box position 0..N-1, count how many
///      windows have an alive sub-box at that position. If fewer than
///      half the windows do, the position is non-rhythmic — mark it
///      dead in ALL windows.
///   4. Re-pick: for each window, find argmax over only the alive
///      sub-boxes. If no sub-box is alive, fall back to the window
///      center (which will produce low energy at the next gate,
///      causing confirmation to skip the window).
///
/// Notes:
///   - Window centers come from the FFT phase calculation, NOT from a
///     regression on the initial picks. The FFT integrates over the
///     full 15 s and is robust to per-window noise events. Using the
///     FFT centers prevents the noise-contaminated picks from biasing
///     the window placement, which would in turn reinforce the noise
///     positions in the consistency check (a feedback loop we tried
///     and explicitly rejected).
///   - For typical rate errors (< 150 s/day), the real ticks drift
///     through their FFT-anchored windows by less than 20 ms over the
///     full 15 s recording — comfortably within one sub-box. Larger
///     rate errors degrade the consistency check gracefully.
///   - Position-consistency assumes ≥ N/2 of windows have a real tick.
///     Below that threshold (very weak watch) real ticks may get killed
///     too. The pass2MinFractionOfWindows knob tunes this tradeoff.
///   - Sub-box width is window/N. Larger N gives finer position
///     resolution but more variance in per-position counts. Default
///     N = 10 keeps each sub-box at ~20 ms.
struct NoiseRejector {
    let smoothed: [Float]
    let sampleRate: Double
    let halfPeriodSamples: Int

    var subBoxesPerWindow: Int = 10
    var pass1MultipleOfFloor: Float = 2.0
    var pass2MinFractionOfWindows: Double = 0.5
    var floorPercentile: Double = 0.7

    /// Re-pick through the noise-cleaned signal. Takes FFT-anchored
    /// window centers (in seconds, length m) and returns m beat positions.
    /// For windows where cleaning killed all sub-boxes, position falls
    /// back to the window center (the confirmation gate downstream will
    /// then skip the window because no tick energy exists at the center
    /// of the cleaned signal).
    func clean(windowCenters: [Double]) -> [Double] {
        let m = windowCenters.count
        guard m >= 6 else { return windowCenters }
        let n = smoothed.count

        let windowSamples = 2 * halfPeriodSamples
        let subBoxWidthSamples = max(1, windowSamples / subBoxesPerWindow)
        var centerSamples = [Int](repeating: 0, count: m)
        for i in 0..<m {
            centerSamples[i] = Int(round(windowCenters[i] * sampleRate))
        }

        // === Step 1: Per-window per-sub-box peak energy ===
        var peakEnergy = Array(repeating: [Float](repeating: 0, count: subBoxesPerWindow), count: m)
        for w in 0..<m {
            let windowStart = centerSamples[w] - halfPeriodSamples
            for sb in 0..<subBoxesPerWindow {
                let lo = max(0, windowStart + sb * subBoxWidthSamples)
                let hi = min(n - 1, windowStart + (sb + 1) * subBoxWidthSamples - 1)
                if lo >= hi { continue }
                var maxV: Float = 0
                for i in lo...hi {
                    if smoothed[i] > maxV { maxV = smoothed[i] }
                }
                peakEnergy[w][sb] = maxV
            }
        }

        // === Step 2: Pass 1 — global noise floor + 2× threshold ===
        let allPeaks = peakEnergy.flatMap { $0 }.sorted()
        let bottomCount = max(1, Int(Double(allPeaks.count) * floorPercentile))
        var floorSum: Float = 0
        for i in 0..<bottomCount { floorSum += allPeaks[i] }
        let noiseFloor = floorSum / Float(bottomCount)
        let pass1Threshold = pass1MultipleOfFloor * noiseFloor

        var alive = Array(repeating: [Bool](repeating: false, count: subBoxesPerWindow), count: m)
        for w in 0..<m {
            for sb in 0..<subBoxesPerWindow {
                if peakEnergy[w][sb] >= pass1Threshold {
                    alive[w][sb] = true
                }
            }
        }

        // === Step 3: Pass 2 — per-position rhythmic-consistency ===
        let consistencyMin = Int(Double(m) * pass2MinFractionOfWindows)
        for sb in 0..<subBoxesPerWindow {
            var count = 0
            for w in 0..<m {
                if alive[w][sb] { count += 1 }
            }
            if count < consistencyMin {
                for w in 0..<m {
                    alive[w][sb] = false
                }
            }
        }

        // === Step 4: Re-pick from alive sub-boxes only ===
        var cleaned = [Double](repeating: 0, count: m)
        for w in 0..<m {
            let windowStart = centerSamples[w] - halfPeriodSamples
            var bestVal: Float = -1
            var bestIdx = -1
            for sb in 0..<subBoxesPerWindow {
                guard alive[w][sb] else { continue }
                let lo = max(0, windowStart + sb * subBoxWidthSamples)
                let hi = min(n - 1, windowStart + (sb + 1) * subBoxWidthSamples - 1)
                if lo >= hi { continue }
                for i in lo...hi {
                    if smoothed[i] > bestVal { bestVal = smoothed[i]; bestIdx = i }
                }
            }
            if bestIdx >= 0 {
                cleaned[w] = Double(bestIdx) / sampleRate
            } else {
                cleaned[w] = windowCenters[w]
            }
        }
        return cleaned
    }
}
