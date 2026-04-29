import Foundation
import Accelerate

/// Matched-filter tick localization, ported from the TickAnatomy research
/// detector after the OmegaStudy corpus showed it cleanly removes the
/// "phantom beat error" the smoothed-argmax + lock-in picker produces on
/// watches with multi-sub-event tick acoustics.
///
/// Algorithm:
/// 1. Build a 20 ms envelope window around each confirmed tick position.
/// 2. Centroid-bootstrap iterated matched filter: align each envelope to
///    its centroid (class-unbiased reference), build a shared template,
///    cross-correlate to refine the alignment, iterate to convergence.
/// 3. 1.5σ class-wise iterative trimming on the refined positions:
///    drop ticks whose residual from the joint regression deviates more
///    than 1.5σ from the per-class mean. Cracks bimodal sub-event-flip
///    distributions that 2σ misses (because σ is inflated by the
///    bimodality itself) and is looser than 1σ (which throws too much
///    away).
///
/// Returns refined absolute times (seconds) per input tick, with `nil`
/// for ticks that were trimmed. Caller reconstructs BE and tickTimings
/// from the survivors; trimmed ticks naturally drop from the display.
enum MatchedFilterRefinement {

    /// Apply matched-filter refinement and 1.5σ trim. Inputs:
    /// - `squared`: pre-computed squared highpass signal (the same one
    ///   the lock-in pass used).
    /// - `sampleRate`: audio sample rate (Hz).
    /// - `tickPositions`: lock-in-refined tick times in seconds, one per
    ///   confirmed tick. (Output of the existing centroid lock-in pass.)
    /// - `beatIndices`: beat number per tick (parallel to `tickPositions`).
    ///
    /// Returns an array of `Double?` parallel to the inputs: refined time
    /// in seconds for kept ticks, `nil` for trimmed ticks.
    static func refinePositions(
        squared: [Float],
        sampleRate: Double,
        tickPositions: [Double],
        beatIndices: [Int]
    ) -> [Double?] {
        precondition(tickPositions.count == beatIndices.count)
        let n = tickPositions.count
        guard n >= 6 else { return tickPositions.map { $0 } }

        // Envelope extraction: 20 ms window per tick (±10 ms), downsampled
        // to 400 points (= 0.05 ms grid). Smooth squared with 0.5 ms moving
        // avg first to match TickAnatomy's envelope shape.
        let envHalfMs: Double = 10.0
        let envPoints = 400
        let msPerPoint = (2.0 * envHalfMs) / Double(envPoints)
        // 0.5 ms smoothing applied per downsample point inside
        // `downsampleEnvelope` — avoids smoothing the full ~720k-sample
        // signal (which is the dominant cost in debug builds where Swift
        // bounds checks dominate). Only ~90 ticks × 400 envelope points
        // × ~24 samples each = ~860k ops total instead of 18M.
        let smoothHalf = max(1, Int(0.00025 * sampleRate))

        // Per-tick envelope + initial offset = 0 (envelope is already
        // centered on the lock-in centroid position from MeasurementPipeline).
        // The matched filter iterates from there to converge on the offset
        // that best aligns each tick's envelope with the shared template.
        var envs = [[Float]](repeating: [], count: n)
        var initialOffsetsMs = [Double?](repeating: nil, count: n)
        for i in 0..<n {
            let centerSample = Int(round(tickPositions[i] * sampleRate))
            envs[i] = downsampleEnvelope(
                squared: squared,
                centerSample: centerSample,
                sampleRate: sampleRate,
                halfMs: envHalfMs,
                points: envPoints,
                smoothHalf: smoothHalf
            )
            initialOffsetsMs[i] = 0.0
        }

        // Iterated matched filter. Pass 0 aligns by centroid; passes 1+
        // align by the previous matched-filter offset.
        var offsetMs = initialOffsetsMs
        let maxIters = 5
        let convergeMs = 0.01
        for _ in 0..<maxIters {
            let template = buildAlignedTemplate(
                envs: envs, offsetMs: offsetMs, msPerPoint: msPerPoint
            )
            guard !template.isEmpty else { break }
            let prev = offsetMs
            offsetMs = matchedFilterPass(
                envs: envs, template: template, offsetMs: offsetMs,
                msPerPoint: msPerPoint, searchHalfMs: 2.0
            )
            // Convergence check: max change across all kept ticks.
            var maxDelta = 0.0
            for k in 0..<n {
                guard let p = prev[k], let c = offsetMs[k] else { continue }
                maxDelta = max(maxDelta, abs(c - p))
            }
            if maxDelta < convergeMs { break }
        }

        // 1.5σ class-wise iterative trim on the matched-filter positions.
        var keptFlags = [Bool](repeating: true, count: n)
        for i in 0..<n where offsetMs[i] == nil { keptFlags[i] = false }
        let trimK = 1.5
        let trimIters = 4
        for _ in 0..<trimIters {
            // Joint regression on (beatIndex, refined absolute time).
            var sumBi = 0.0, sumPos = 0.0; var nKept = 0
            var positions = [Double](repeating: 0, count: n)
            for i in 0..<n where keptFlags[i] {
                guard let off = offsetMs[i] else { continue }
                positions[i] = tickPositions[i] + off / 1000.0
                sumBi += Double(beatIndices[i]); sumPos += positions[i]; nKept += 1
            }
            guard nKept >= 4 else { break }
            let meanBi = sumBi / Double(nKept)
            let meanPos = sumPos / Double(nKept)
            var sxx = 0.0, sxy = 0.0
            for i in 0..<n where keptFlags[i] && offsetMs[i] != nil {
                let dx = Double(beatIndices[i]) - meanBi
                let dy = positions[i] - meanPos
                sxx += dx * dx; sxy += dx * dy
            }
            let slope = sxx > 0 ? sxy / sxx : 0
            let intercept = meanPos - slope * meanBi
            // Per-class mean and σ of residuals.
            var sumE = 0.0, sumO = 0.0; var ne = 0, no = 0
            var residuals = [Double](repeating: 0, count: n)
            for i in 0..<n where keptFlags[i] && offsetMs[i] != nil {
                residuals[i] = positions[i] - (slope * Double(beatIndices[i]) + intercept)
                if beatIndices[i] % 2 == 0 { sumE += residuals[i]; ne += 1 }
                else                       { sumO += residuals[i]; no += 1 }
            }
            let muE = ne > 0 ? sumE / Double(ne) : 0
            let muO = no > 0 ? sumO / Double(no) : 0
            var ssE = 0.0, ssO = 0.0
            for i in 0..<n where keptFlags[i] && offsetMs[i] != nil {
                let mu = beatIndices[i] % 2 == 0 ? muE : muO
                let d = residuals[i] - mu
                if beatIndices[i] % 2 == 0 { ssE += d * d } else { ssO += d * d }
            }
            let sdE = ne > 1 ? sqrt(ssE / Double(ne)) : 0
            let sdO = no > 1 ? sqrt(ssO / Double(no)) : 0
            var changed = false
            for i in 0..<n where keptFlags[i] && offsetMs[i] != nil {
                let mu = beatIndices[i] % 2 == 0 ? muE : muO
                let sd = beatIndices[i] % 2 == 0 ? sdE : sdO
                if sd > 0 && abs(residuals[i] - mu) > trimK * sd {
                    keptFlags[i] = false; changed = true
                }
            }
            if !changed { break }
        }

        // Build refined absolute times. Trimmed ticks return nil.
        var out = [Double?](repeating: nil, count: n)
        for i in 0..<n where keptFlags[i] {
            guard let off = offsetMs[i] else { continue }
            out[i] = tickPositions[i] + off / 1000.0
        }
        return out
    }

    // MARK: - Internal helpers

    /// Sample a 20 ms window around `centerSample` from the squared
    /// signal, smoothing inline by averaging ±`smoothHalf` samples around
    /// each downsample point. Skipping the full-signal smoothing pass
    /// keeps the work O(envelopes × points × smoothWindow) instead of
    /// O(samples × smoothWindow), critical in debug builds.
    private static func downsampleEnvelope(
        squared: [Float],
        centerSample: Int,
        sampleRate: Double,
        halfMs: Double,
        points: Int,
        smoothHalf: Int
    ) -> [Float] {
        var out = [Float](repeating: 0, count: points)
        let n = squared.count
        for k in 0..<points {
            let frac = Double(k) / Double(points - 1)
            let msFromCenter = -halfMs + frac * (2.0 * halfMs)
            let absIdx = centerSample + Int(round(msFromCenter / 1000.0 * sampleRate))
            if absIdx >= 0 && absIdx < n {
                let lo = max(0, absIdx - smoothHalf)
                let hi = min(n - 1, absIdx + smoothHalf)
                var s: Float = 0
                for j in lo...hi { s += squared[j] }
                out[k] = s / Float(hi - lo + 1)
            }
        }
        return out
    }

    /// Centroid of the envelope (offset from array center, in ms).
    /// Treats the envelope as an energy distribution; returns the
    /// energy-weighted mean position relative to the array's center.
    /// Returns nil if the envelope is degenerate.
    private static func envelopeCentroidMs(_ env: [Float], msPerPoint: Double) -> Double? {
        let n = env.count
        guard n > 0 else { return nil }
        var minVal = env[0]
        for v in env { if v < minVal { minVal = v } }
        var num = 0.0, den = 0.0
        let halfLen = n / 2
        for i in 0..<n {
            let w = Double(env[i] - minVal)
            if w > 0 {
                num += w * Double(i - halfLen)
                den += w
            }
        }
        guard den > 0 else { return nil }
        return (num / den) * msPerPoint
    }

    /// Build an average envelope template, with each contributing
    /// envelope sub-sample-shifted so that `offsetMs[i]` lies at the
    /// array center. Each contribution is peak-normalized so loud ticks
    /// don't dominate. Mirrors TickAnatomy's `buildAlignedTemplate`.
    private static func buildAlignedTemplate(
        envs: [[Float]], offsetMs: [Double?], msPerPoint: Double
    ) -> [Float] {
        guard let first = envs.first else { return [] }
        let n = first.count
        guard n > 0 else { return [] }
        let halfLen = n / 2
        var sum = [Float](repeating: 0, count: n)
        var contributors: Float = 0
        for i in 0..<envs.count {
            guard envs[i].count == n, let off = offsetMs[i] else { continue }
            let centerSample = Double(halfLen) + off / msPerPoint
            let aligned = shiftedCopy(source: envs[i],
                                      centerSample: centerSample,
                                      length: n)
            let peak = aligned.max() ?? 0
            guard peak > 0 else { continue }
            let inv = 1.0 / peak
            for k in 0..<n { sum[k] += aligned[k] * inv }
            contributors += 1
        }
        if contributors > 0 { for k in 0..<n { sum[k] /= contributors } }
        return sum
    }

    /// One pass of matched-filter refinement: align each envelope by
    /// `offsetMs[i]`, cross-correlate against template, return new
    /// `offsetMs` = old + lag. Mirrors TickAnatomy's `matchedFilterPass`.
    private static func matchedFilterPass(
        envs: [[Float]], template: [Float], offsetMs: [Double?],
        msPerPoint: Double, searchHalfMs: Double
    ) -> [Double?] {
        guard !template.isEmpty else { return offsetMs }
        var out = [Double?](repeating: nil, count: envs.count)
        let n = template.count
        let halfLen = n / 2
        let maxLagPoints = max(1, Int(searchHalfMs / msPerPoint))
        for i in 0..<envs.count {
            guard envs[i].count == n, let off = offsetMs[i] else { continue }
            let centerSample = Double(halfLen) + off / msPerPoint
            let aligned = shiftedCopy(source: envs[i],
                                      centerSample: centerSample,
                                      length: n)
            let lagPoints = subSampleLag(template: template,
                                         candidate: aligned,
                                         maxLag: maxLagPoints)
            out[i] = off + lagPoints * msPerPoint
        }
        return out
    }

    /// Linear-interpolate a shifted copy of `source` such that the new
    /// center aligns sub-sample with the template. Returns an array of
    /// `length`. The fractional shift is constant across the output, so
    /// the in-bounds case is a single vDSP_vsmsma call (vectorized linear
    /// blend between source[lo..lo+length] and source[lo+1..lo+length+1]).
    /// Edge handling falls back to scalar.
    private static func shiftedCopy(source: [Float], centerSample: Double, length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        let halfLen = length / 2
        let sn = source.count
        // Position of source[i] for output[i = halfLen + k] is centerSample + k.
        // Output index 0 reads source at centerSample - halfLen.
        let firstSrc = centerSample - Double(halfLen)
        let lo0 = Int(floor(firstSrc))
        let frac = Float(firstSrc - Double(lo0))
        let oneMinusFrac = 1 - frac
        // Need source[lo0 .. lo0 + length] for the low buffer and
        // source[lo0 + 1 .. lo0 + length + 1] for the high buffer.
        if lo0 >= 0 && lo0 + length + 1 <= sn {
            // Fully in bounds — single vectorized blend.
            source.withUnsafeBufferPointer { sp in
                guard let base = sp.baseAddress else { return }
                out.withUnsafeMutableBufferPointer { op in
                    guard let oBase = op.baseAddress else { return }
                    var a = oneMinusFrac, b = frac
                    vDSP_vsmsma(base + lo0, 1, &a,
                                base + lo0 + 1, 1, &b,
                                oBase, 1, vDSP_Length(length))
                }
            }
        } else {
            // Edge case (rare in practice — envelope falls partly outside
            // the signal) — fall back to per-element with bounds checks.
            for i in 0..<length {
                let srcPos = centerSample + Double(i - halfLen)
                let lo = Int(floor(srcPos))
                let hi = lo + 1
                let f = Float(srcPos - Double(lo))
                if lo >= 0 && hi < sn {
                    out[i] = source[lo] * (1 - f) + source[hi] * f
                }
            }
        }
        return out
    }

    /// Cross-correlate `template` against `candidate` over lags ±maxLag
    /// (in samples). Returns the parabolically-refined sub-sample lag
    /// that maximizes correlation. The inner per-lag dot product is
    /// vectorized with vDSP_dotpr — critical for debug-build performance
    /// since this is called per-tick × per-iteration (~450 times per
    /// measurement, each with ~80 lag values), and a hand-rolled Swift
    /// loop pays heavy array bounds-check overhead in debug.
    private static func subSampleLag(template: [Float], candidate: [Float], maxLag: Int) -> Double {
        precondition(template.count == candidate.count)
        let n = template.count
        var bestLag = 0
        var bestCorr: Float = -.infinity
        var corrByLag = [Float](repeating: 0, count: 2 * maxLag + 1)
        template.withUnsafeBufferPointer { tp in
            candidate.withUnsafeBufferPointer { cp in
                guard let tBase = tp.baseAddress, let cBase = cp.baseAddress else { return }
                for lag in -maxLag...maxLag {
                    let aStart = max(0, -lag)
                    let aEnd = min(n, n - lag)
                    let count = aEnd - aStart
                    guard count > 0 else { continue }
                    var acc: Float = 0
                    vDSP_dotpr(tBase + aStart, 1,
                               cBase + aStart + lag, 1,
                               &acc, vDSP_Length(count))
                    corrByLag[lag + maxLag] = acc
                    if acc > bestCorr { bestCorr = acc; bestLag = lag }
                }
            }
        }
        let idx = bestLag + maxLag
        if idx > 0 && idx < corrByLag.count - 1 {
            let y0 = corrByLag[idx - 1], y1 = corrByLag[idx], y2 = corrByLag[idx + 1]
            let denom = y0 - 2 * y1 + y2
            if denom != 0 {
                let r = 0.5 * (y0 - y2) / denom
                if abs(r) <= 1.0 { return Double(bestLag) + Double(r) }
            }
        }
        return Double(bestLag)
    }
}
