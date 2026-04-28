import Foundation
import Accelerate
import WatchBeatCore

// Coherent averaging of the highest-quality ticks in a recording, split into
// ticks (even beats) and tocks (odd beats). Averaging N aligned copies of the
// same event gives √N SNR gain, so sub-events (unlock / impulse / drop) that
// are buried in a single tick can become visible in the average.
//
// Alignment is sub-sample via cross-correlation against a reference tick,
// refined with parabolic interpolation of the correlation peak.
//
// Usage:
//   swift run -c release TickAnatomy <file.wav> [<file2.wav> ...]
//   swift run -c release TickAnatomy <directory>
// If no args, processes every .wav in SoundSamples/.
// Output: <file>.anatomy.csv in the current directory.

// MARK: - CLI arg parsing

var rawArgs = Array(CommandLine.arguments.dropFirst())

// Parse --lift-angle=XX. Default matches Tim's Omega cal 485.
var liftAngleDeg: Double = 52.0
rawArgs.removeAll { arg in
    if arg.hasPrefix("--lift-angle=") {
        if let v = Double(arg.dropFirst("--lift-angle=".count)) { liftAngleDeg = v }
        return true
    }
    return false
}

let args = rawArgs
let baseDir = "SoundSamples"

func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    return exists && isDir.boolValue
}

func resolve(_ path: String) -> String {
    if FileManager.default.fileExists(atPath: path) { return path }
    let joined = (baseDir as NSString).appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: joined) { return joined }
    return path
}

func listWavs(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".wav") }
        .sorted()
        .map { (dir as NSString).appendingPathComponent($0) }
}

let files: [String] = {
    if args.isEmpty { return listWavs(baseDir) }
    if args.count == 1, isDirectory(args[0]) { return listWavs(args[0]) }
    return args.map { resolve($0) }
}()

if files.isEmpty {
    FileHandle.standardError.write("No .wav files found.\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Helpers

/// ±halfWindow around the tick center. 15ms either side comfortably contains a 3–5ms tick
/// plus context, while fitting inside the gap between ticks (shortest is 36000 bph = 100ms).
let halfWindowMs: Double = 15.0

/// Minimum ticks to bother averaging (per class).
let minTicksForAverage = 8

/// Number of top-quality ticks to keep (per class). Half this gives the tock cohort.
let topPerClass = 120

/// Sub-sample alignment lag range (±2ms). Wider than any expected inter-tick jitter.
let alignLagMs: Double = 2.0

func tickPositionSamples(
    beatIndex: Int, residualMs: Double, beatPeriod: Double, sampleOffset: Double, sampleRate: Double
) -> Double {
    beatPeriod * sampleRate * Double(beatIndex) + sampleOffset + (residualMs / 1000.0) * sampleRate
}

/// Peak amplitude inside a window, for normalization.
func peakAbs(_ samples: ArraySlice<Float>) -> Float {
    var peak: Float = 0
    for s in samples { let a = abs(s); if a > peak { peak = a } }
    return peak
}

/// RMS inside a range (inclusive bounds).
func rms(_ samples: [Float], from: Int, to: Int) -> Float {
    guard from <= to, from >= 0, to < samples.count else { return 0 }
    let count = to - from + 1
    var acc: Float = 0
    for i in from...to { acc += samples[i] * samples[i] }
    return sqrt(acc / Float(count))
}

/// Tick quality metric: peak inside the core window divided by RMS outside it.
/// Bigger = sharper and cleaner.
func tickSnr(_ signal: [Float], center: Int, coreHalf: Int, windowHalf: Int) -> Float {
    let n = signal.count
    let coreLo = max(0, center - coreHalf)
    let coreHi = min(n - 1, center + coreHalf)
    let winLo = max(0, center - windowHalf)
    let winHi = min(n - 1, center + windowHalf)
    guard coreLo > winLo, coreHi < winHi else { return 0 }

    var peak: Float = 0
    for i in coreLo...coreHi { let a = abs(signal[i]); if a > peak { peak = a } }

    var noiseAcc: Float = 0
    var noiseCount = 0
    for i in winLo..<coreLo { noiseAcc += signal[i] * signal[i]; noiseCount += 1 }
    for i in (coreHi + 1)...winHi { noiseAcc += signal[i] * signal[i]; noiseCount += 1 }
    guard noiseCount > 0, noiseAcc > 0 else { return 0 }
    let noiseRms = sqrt(noiseAcc / Float(noiseCount))
    return peak / noiseRms
}

/// Cross-correlate candidate against template over a small lag range, return
/// sub-sample lag that maximizes correlation. Lag is in samples, positive =
/// candidate lags template.
func subSampleLag(template: [Float], candidate: [Float], maxLag: Int) -> Double {
    precondition(template.count == candidate.count)
    let n = template.count
    var bestLag = 0
    var bestCorr: Double = -.infinity
    var corrByLag = [Double](repeating: 0, count: 2 * maxLag + 1)

    for lag in -maxLag...maxLag {
        var acc: Double = 0
        let aStart = max(0, -lag)
        let aEnd = min(n, n - lag)
        for i in aStart..<aEnd {
            acc += Double(template[i]) * Double(candidate[i + lag])
        }
        corrByLag[lag + maxLag] = acc
        if acc > bestCorr { bestCorr = acc; bestLag = lag }
    }

    // Parabolic refinement around the peak bin.
    let idx = bestLag + maxLag
    if idx > 0 && idx < corrByLag.count - 1 {
        let y0 = corrByLag[idx - 1], y1 = corrByLag[idx], y2 = corrByLag[idx + 1]
        let denom = y0 - 2 * y1 + y2
        if denom != 0 {
            let refinement = 0.5 * (y0 - y2) / denom
            if abs(refinement) <= 1.0 {
                return Double(bestLag) + refinement
            }
        }
    }
    return Double(bestLag)
}

/// Linear-interpolate a shifted copy of `source` such that the new center
/// aligns sub-sample with the template. Returns an array of `length`.
func shiftedCopy(source: [Float], centerSample: Double, length: Int) -> [Float] {
    var out = [Float](repeating: 0, count: length)
    let halfLen = length / 2
    let n = source.count
    for i in 0..<length {
        let srcPos = centerSample + Double(i - halfLen)
        let lo = Int(floor(srcPos))
        let hi = lo + 1
        let frac = Float(srcPos - Double(lo))
        if lo >= 0 && hi < n {
            out[i] = source[lo] * (1 - frac) + source[hi] * frac
        }
    }
    return out
}

func movingAvg(_ x: [Float], window: Int) -> [Float] {
    guard window > 1, window <= x.count else { return x }
    let out = x.count
    var result = [Float](repeating: 0, count: out)
    var sum: Float = 0
    let half = window / 2
    for i in 0..<min(window, x.count) { sum += x[i] }
    for i in 0..<out {
        let lo = max(0, i - half)
        let hi = min(x.count - 1, i + window - 1 - half)
        if i > half {
            sum += x[min(x.count - 1, i + window - 1 - half)] - x[max(0, i - half - 1)]
        }
        // Simple clamped-range mean — robust at edges.
        var acc: Float = 0
        var c: Int = 0
        for j in lo...hi { acc += x[j]; c += 1 }
        result[i] = c > 0 ? acc / Float(c) : 0
    }
    return result
}

/// Envelope: abs + short smoothing. Window tuned to keep unlock/impulse/drop
/// sub-events resolvable — 0.15 ms is short enough that adjacent events don't
/// smear into a single blob.
func envelope(_ x: [Float], sampleRate: Double, smoothingMs: Double = 0.15) -> [Float] {
    var abs_ = [Float](repeating: 0, count: x.count)
    vDSP_vabs(x, 1, &abs_, 1, vDSP_Length(x.count))
    let win = max(3, Int(smoothingMs / 1000.0 * sampleRate))
    return movingAvg(abs_, window: win)
}

// MARK: - Per-file processing

struct Averaged {
    let waveform: [Float]
    let envelope: [Float]        // fine envelope (0.15ms smoothing) — shows sub-structure
    let midEnvelope: [Float]     // medium envelope (1ms smoothing) — candidate "best of both worlds"
    let pulseEnvelope: [Float]   // wide envelope (3ms smoothing) — matches current AmplitudeEstimator
    let count: Int
    let keptSnr: [Float]         // SNRs of ticks actually used
}

/// Per-tick pulse-width distribution for one class (tick or tock). Each entry
/// is the measured width at 20% of that individual tick's envelope peak.
struct PerTickWidths {
    let widthsMs: [Double]
    var count: Int { widthsMs.count }
    var median: Double? {
        guard !widthsMs.isEmpty else { return nil }
        let s = widthsMs.sorted()
        return s[s.count / 2]
    }
    var mean: Double? {
        guard !widthsMs.isEmpty else { return nil }
        return widthsMs.reduce(0, +) / Double(widthsMs.count)
    }
    var std: Double? {
        guard widthsMs.count > 1, let m = mean else { return nil }
        let sumSq = widthsMs.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
        return sqrt(sumSq / Double(widthsMs.count - 1))
    }
    /// Width at a given percentile (0-100).
    func percentile(_ p: Double) -> Double? {
        guard !widthsMs.isEmpty else { return nil }
        let s = widthsMs.sorted()
        let idx = min(s.count - 1, max(0, Int(Double(s.count - 1) * p / 100.0)))
        return s[idx]
    }
}

/// Per-tick distribution with paired pulse-width and amplitude values. Used by
/// the per-tick vacaboja path: each tick runs its own threshold sweep, so not
/// every tick yields a reading, and the kept entries are those that converged.
struct PerTickAmps {
    let pulsesMs: [Double]
    let ampsDeg: [Double]
    var count: Int { pulsesMs.count }
    private func sortedMedian(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[s.count / 2]
    }
    private func sortedPercentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let idx = min(s.count - 1, max(0, Int(Double(s.count - 1) * p / 100.0)))
        return s[idx]
    }
    var medianPulseMs: Double? { sortedMedian(pulsesMs) }
    var medianAmpDeg: Double? { sortedMedian(ampsDeg) }
    var p25AmpDeg: Double? { sortedPercentile(ampsDeg, 25) }
    var p75AmpDeg: Double? { sortedPercentile(ampsDeg, 75) }
    var meanAmpDeg: Double? {
        guard !ampsDeg.isEmpty else { return nil }
        return ampsDeg.reduce(0, +) / Double(ampsDeg.count)
    }
    var stdAmpDeg: Double? {
        guard ampsDeg.count > 1, let m = meanAmpDeg else { return nil }
        let sumSq = ampsDeg.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
        return sqrt(sumSq / Double(ampsDeg.count - 1))
    }
    /// Standard error of the median ≈ 1.2533 · stdev / √n (Laplace approx).
    var medianStdErrDeg: Double? {
        guard let s = stdAmpDeg, count > 1 else { return nil }
        return 1.2533 * s / sqrt(Double(count))
    }
}

/// Per-tick trace with candidate picker positions. One entry per individual
/// tick; used to compare centroid (current production) vs onset (proposed)
/// detectors visually. Traces are stored downsampled for plotting size.
struct PerTickTrace {
    let beatIndex: Int
    let isEven: Bool
    let centerSampleAbs: Int          // absolute sample index of original argmax
    let envSamples: [Float]           // 0.5ms-smoothed envelope, downsampled
    let fluxSamples: [Float]          // spectral flux detection function, same grid
    let envSampleRate: Double         // effective sample rate of env/flux samples
    let envHalfMs: Double             // half-width of samples in ms
    // Picker candidate offsets, all in ms relative to centerSampleAbs.
    let argmaxMs: Double              // smoothed-envelope argmax (anchor)
    let centroidMs: Double?           // centroid in ±5ms of squared (production)
    let onsetMs20pct: Double?         // walk-back from argmax to 20% of peak
    let onsetMs5sigma: Double?        // walk-back from argmax to baseline + 5σ
    let fluxPeakMs: Double?           // spectral-flux peak inside ±10ms window
    let fluxOnsetMs: Double?          // leading edge of the flux peak (50% of flux max)
    let fluxFirstMs: Double?          // first flux peak above 30% of window max (early-stopping)
    let matchedMs: Double?            // matched-filter alignment vs class-template (sub-event-flip-resistant)
}

/// Build an average envelope template from a set of per-tick traces, with
/// each trace's envelope first sub-sample-shifted so the supplied `offset`
/// (in ms from argmax) lies at the array center. With `offset = centroidMs`
/// this gives a centroid-aligned template; on iteration passes the offset
/// becomes the matched-filter refined position from the previous pass.
/// Each contribution is peak-normalized so loud ticks don't dominate.
func buildAlignedTemplate(
    _ traces: [PerTickTrace],
    offsetMs: (PerTickTrace) -> Double?
) -> [Float] {
    guard let first = traces.first else { return [] }
    let n = first.envSamples.count
    guard n > 0 else { return [] }
    let halfLen = n / 2
    var sum = [Float](repeating: 0, count: n)
    var contributors: Float = 0
    for t in traces {
        guard t.envSamples.count == n, let off = offsetMs(t) else { continue }
        let msPerPoint = 1000.0 / t.envSampleRate
        let centerSample = Double(halfLen) + off / msPerPoint
        let aligned = shiftedCopy(source: t.envSamples,
                                  centerSample: centerSample,
                                  length: n)
        let peak = aligned.max() ?? 0
        guard peak > 0 else { continue }
        let inv = 1.0 / peak
        for i in 0..<n { sum[i] += aligned[i] * inv }
        contributors += 1
    }
    if contributors > 0 { for i in 0..<n { sum[i] /= contributors } }
    return sum
}

/// One pass of matched-filter refinement: align each trace by `offsetMs` so
/// the current best-guess reference lies at center, cross-correlate against
/// the template, and store the refined offset (`old offset + lag`) into
/// `matchedMs`. `searchHalfMs` controls how far the lag is allowed to roam
/// — small (±2 ms) for normal iterations where the template inherits the
/// candidate's reference; large (±10 ms) for the outlier-rescue pass where
/// the template is built from inliers only and outlier ticks need to
/// migrate to the dominant sub-event.
func matchedFilterPass(
    _ traces: [PerTickTrace],
    template: [Float],
    offsetMs: (PerTickTrace) -> Double?,
    searchHalfMs: Double = 2.0
) -> [PerTickTrace] {
    guard !template.isEmpty else { return traces }
    return traces.map { t in
        let n = t.envSamples.count
        guard n == template.count, let off = offsetMs(t) else {
            return PerTickTrace(beatIndex: t.beatIndex, isEven: t.isEven,
                centerSampleAbs: t.centerSampleAbs, envSamples: t.envSamples,
                fluxSamples: t.fluxSamples, envSampleRate: t.envSampleRate,
                envHalfMs: t.envHalfMs, argmaxMs: t.argmaxMs,
                centroidMs: t.centroidMs, onsetMs20pct: t.onsetMs20pct,
                onsetMs5sigma: t.onsetMs5sigma, fluxPeakMs: t.fluxPeakMs,
                fluxOnsetMs: t.fluxOnsetMs, fluxFirstMs: t.fluxFirstMs,
                matchedMs: nil)
        }
        let msPerPoint = 1000.0 / t.envSampleRate
        let halfLen = n / 2
        let centerSample = Double(halfLen) + off / msPerPoint
        let aligned = shiftedCopy(source: t.envSamples,
                                  centerSample: centerSample,
                                  length: n)
        let maxLagPoints = max(1, Int(searchHalfMs / msPerPoint))
        let lagPoints = subSampleLag(template: template,
                                     candidate: aligned,
                                     maxLag: maxLagPoints)
        let lagMs = lagPoints * msPerPoint
        return PerTickTrace(beatIndex: t.beatIndex, isEven: t.isEven,
            centerSampleAbs: t.centerSampleAbs, envSamples: t.envSamples,
            fluxSamples: t.fluxSamples, envSampleRate: t.envSampleRate,
            envHalfMs: t.envHalfMs, argmaxMs: t.argmaxMs,
            centroidMs: t.centroidMs, onsetMs20pct: t.onsetMs20pct,
            onsetMs5sigma: t.onsetMs5sigma, fluxPeakMs: t.fluxPeakMs,
            fluxOnsetMs: t.fluxOnsetMs, fluxFirstMs: t.fluxFirstMs,
            matchedMs: off + lagMs)
    }
}

/// Short-time spectral flux on a real-valued signal. For each STFT frame, sums
/// positive magnitude differences across all bins, which gives a high score on
/// fast broadband attacks (ticks) and a low score on sustained narrowband
/// ringing. Returns (flux per frame, hop in samples) — frame center for frame f
/// is f*hop + window/2 in the input.
///
/// Window/hop chosen for tick-grain time resolution: at 44.1 kHz, window=128
/// ≈ 2.9 ms, hop=32 ≈ 0.73 ms. Window is short enough that a single tick
/// occupies ~1-2 frames so its onset shows as a sharp flux spike rather than
/// being smeared across many frames; hop is short enough for sub-ms peak
/// localization after parabolic interpolation.
func spectralFlux(_ signal: [Float], window: Int = 128, hop: Int = 32) -> [Float] {
    let n = signal.count
    guard n > window + hop else { return [] }
    let nFrames = (n - window) / hop + 1
    let log2n = vDSP_Length(log2(Double(window)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
    defer { vDSP_destroy_fftsetup(setup) }

    // Hann window (precomputed).
    var hann = [Float](repeating: 0, count: window)
    vDSP_hann_window(&hann, vDSP_Length(window), Int32(vDSP_HANN_NORM))

    var prevMag = [Float](repeating: 0, count: window / 2)
    var flux = [Float](repeating: 0, count: nFrames)

    var frame = [Float](repeating: 0, count: window)
    var real = [Float](repeating: 0, count: window / 2)
    var imag = [Float](repeating: 0, count: window / 2)
    var mag = [Float](repeating: 0, count: window / 2)

    for f in 0..<nFrames {
        let start = f * hop
        // Window the input into `frame`.
        signal.withUnsafeBufferPointer { sp in
            vDSP_vmul(sp.baseAddress! + start, 1,
                      hann, 1, &frame, 1, vDSP_Length(window))
        }
        // FFT inside one explicit pointer scope so DSPSplitComplex's raw
        // pointers stay valid through ctoz, fft, and zvabs.
        real.withUnsafeMutableBufferPointer { rp in
        imag.withUnsafeMutableBufferPointer { ip in
        mag.withUnsafeMutableBufferPointer { mp in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            frame.withUnsafeBufferPointer { fp in
                fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: window / 2) { cp in
                    vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(window / 2))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(window / 2))
        }}}
        // Sum positive magnitude differences across bins.
        var s: Float = 0
        for k in 1..<(window / 2) {
            let d = mag[k] - prevMag[k]
            if d > 0 { s += d }
        }
        flux[f] = s
        for k in 0..<(window / 2) { prevMag[k] = mag[k] }
    }
    return flux
}

struct AnatomyResult {
    let filename: String
    let sampleRate: Double
    let beatPeriod: Double
    let snappedBph: Int
    let quality: Int
    let tickAvg: Averaged?
    let tockAvg: Averaged?
    let tickPerTick: PerTickWidths?    // 1ms smoothing
    let tockPerTick: PerTickWidths?
    let tickPerTick3: PerTickWidths?   // 3ms smoothing (matches AmplitudeEstimator)
    let tockPerTick3: PerTickWidths?
    let tickPerTickVac: PerTickAmps?   // vacaboja's method, per individual tick
    let tockPerTickVac: PerTickAmps?
    let tickTraces: [PerTickTrace]
    let tockTraces: [PerTickTrace]
}

func processFile(_ path: String) -> AnatomyResult? {
    let url = URL(fileURLWithPath: path)
    guard let buffer = try? WAVReader.read(url: url) else {
        FileHandle.standardError.write("skip (read failed): \(path)\n".data(using: .utf8)!)
        return nil
    }

    let pipeline = MeasurementPipeline()
    let (result, diag) = pipeline.measureWithDiagnostics(buffer)

    guard result.qualityScore > 0.05, result.tickTimings.count >= 2 * minTicksForAverage else {
        FileHandle.standardError.write(
            "skip (q=\(Int(result.qualityScore * 100))% ticks=\(result.tickTimings.count)): \(url.lastPathComponent)\n"
                .data(using: .utf8)!)
        return nil
    }

    let sampleRate = diag.sampleRate

    // Use the same 5 kHz HP as the main pipeline — that's where the useful tick energy lives.
    let conditioner = SignalConditioner()
    let filtered = conditioner.highpassFilter(
        buffer.samples, sampleRate: sampleRate, cutoff: MeasurementPipeline.highpassCutoffHz
    )

    let beatPeriod = result.snappedRate.nominalPeriodSeconds * (1.0 - result.rateErrorSecondsPerDay / 86400.0)

    // Calibrate sample offset from the first two beat periods — finds where
    // the first tick landed relative to beatIndex=0.
    let searchEnd = min(Int(beatPeriod * sampleRate * 3), filtered.count)
    var calibPeak = 0
    var calibVal: Float = 0
    for i in 0..<searchEnd {
        let v = abs(filtered[i])
        if v > calibVal { calibVal = v; calibPeak = i }
    }
    let estimatedBeat = Double(calibPeak) / (beatPeriod * sampleRate)
    let nearestBeat = Int(round(estimatedBeat))
    let sampleOffset = Double(calibPeak) - beatPeriod * sampleRate * Double(nearestBeat)

    let halfWindow = Int(halfWindowMs / 1000.0 * sampleRate)
    let windowLen = 2 * halfWindow + 1
    let coreHalf = Int(0.0025 * sampleRate)   // 2.5 ms — brackets the dominant tick transient
    let alignLag = Int(alignLagMs / 1000.0 * sampleRate)

    struct Candidate { let center: Int; let snr: Float; let isEven: Bool; let beatIndex: Int }
    var candidates: [Candidate] = []

    for t in result.tickTimings {
        let pos = tickPositionSamples(
            beatIndex: t.beatIndex, residualMs: t.residualMs,
            beatPeriod: beatPeriod, sampleOffset: sampleOffset, sampleRate: sampleRate
        )
        let center = Int(round(pos))
        if center - halfWindow < 0 || center + halfWindow >= filtered.count { continue }
        let snr = tickSnr(filtered, center: center, coreHalf: coreHalf, windowHalf: halfWindow)
        candidates.append(.init(center: center, snr: snr, isEven: t.isEvenBeat, beatIndex: t.beatIndex))
    }

    func averageClass(isEven: Bool) -> Averaged? {
        let pool = candidates
            .filter { $0.isEven == isEven }
            .sorted { $0.snr > $1.snr }
        let kept = Array(pool.prefix(topPerClass))
        guard kept.count >= minTicksForAverage else { return nil }

        // Template: shift the highest-SNR tick into the window. Use its integer center directly.
        let templateCenter = Double(kept[0].center)
        var template = shiftedCopy(source: filtered, centerSample: templateCenter, length: windowLen)
        // Normalize template to unit peak so subsequent correlations are comparable.
        if let tp = template.max(by: { abs($0) < abs($1) }).map({ abs($0) }), tp > 0 {
            vDSP_vsmul(template, 1, [1.0 / tp], &template, 1, vDSP_Length(windowLen))
        }

        var accum = [Float](repeating: 0, count: windowLen)
        var used = 0
        var usedSnr: [Float] = []

        for c in kept {
            // Rough aligned copy.
            let rough = shiftedCopy(source: filtered, centerSample: Double(c.center), length: windowLen)
            // Correlate against template to find residual sub-sample shift.
            let lag = subSampleLag(template: template, candidate: rough, maxLag: alignLag)
            // Re-extract with refined center.
            let refined = shiftedCopy(source: filtered, centerSample: Double(c.center) + lag, length: windowLen)
            // Amplitude-normalize so loud ticks don't dominate.
            var contribution = refined
            if let p = contribution.max(by: { abs($0) < abs($1) }).map({ abs($0) }), p > 0 {
                vDSP_vsmul(contribution, 1, [1.0 / p], &contribution, 1, vDSP_Length(windowLen))
            } else {
                continue
            }
            for i in 0..<windowLen {
                accum[i] += contribution[i]
            }
            used += 1
            usedSnr.append(c.snr)
        }

        guard used >= minTicksForAverage else { return nil }
        let div: Float = 1.0 / Float(used)
        vDSP_vsmul(accum, 1, [div], &accum, 1, vDSP_Length(windowLen))
        // Compute envelope from the averaged waveform, not by averaging per-tick
        // envelopes. Coherent averaging of the raw waveform gives √N SNR gain;
        // deriving the envelope after averaging preserves sign-dependent phase
        // cancellation of noise (incoherent averaging of envelopes does not).
        let envFine = envelope(accum, sampleRate: sampleRate, smoothingMs: 0.15)
        let envMid = envelope(accum, sampleRate: sampleRate, smoothingMs: 1.0)
        let envPulse = envelope(accum, sampleRate: sampleRate, smoothingMs: 3.0)
        return Averaged(waveform: accum, envelope: envFine, midEnvelope: envMid, pulseEnvelope: envPulse,
                        count: used, keptSnr: usedSnr)
    }

    let tickAvg = averageClass(isEven: true)
    let tockAvg = averageClass(isEven: false)

    // Per-tick pulse-width measurement at both 1ms and 3ms smoothing. 3ms is
    // the apples-to-apples comparison to AmplitudeEstimator (which also uses
    // 3ms on its folded signal) — the key test is whether per-tick-at-3ms
    // produces Witschi-compatible widths without needing the fold step.
    func perTickWidths(isEven: Bool, smoothingMs: Double) -> PerTickWidths {
        var widths: [Double] = []
        for c in candidates where c.isEven == isEven {
            let lo = max(0, c.center - halfWindow)
            let hi = min(filtered.count, c.center + halfWindow + 1)
            guard hi > lo else { continue }
            let slice = Array(filtered[lo..<hi])
            let env = envelope(slice, sampleRate: sampleRate, smoothingMs: smoothingMs)
            guard let pw = measurePulseWidth(
                env, sampleRate: sampleRate, halfWindowMs: halfWindowMs, thresholdFraction: 0.20
            ) else { continue }
            if pw.widthMs < 0.3 || pw.widthMs > halfWindowMs * 0.8 { continue }
            widths.append(pw.widthMs)
        }
        return PerTickWidths(widthsMs: widths)
    }
    let tickPerTick = perTickWidths(isEven: true,  smoothingMs: 1.0)
    let tockPerTick = perTickWidths(isEven: false, smoothingMs: 1.0)
    let tickPerTick3 = perTickWidths(isEven: true,  smoothingMs: 3.0)
    let tockPerTick3 = perTickWidths(isEven: false, smoothingMs: 3.0)

    // Per-tick vacaboja: run vacaboja's 1ms peak-hold envelope + threshold
    // sweep on each individual tick's window. Accept ticks where the sweep
    // converges to an amplitude in [135°, 360°]. Ticks and tocks are kept
    // separate so that beat-error-driven asymmetries don't contaminate the
    // combined reading.
    func perTickVacaboja(isEven: Bool) -> PerTickAmps {
        var pulses: [Double] = []
        var amps: [Double] = []
        for c in candidates where c.isEven == isEven {
            let lo = max(0, c.center - halfWindow)
            let hi = min(filtered.count, c.center + halfWindow + 1)
            guard hi > lo else { continue }
            let slice = Array(filtered[lo..<hi])
            let r = vacabojaSingle(
                waveform: slice, sampleRate: sampleRate, beatPeriodSec: beatPeriod,
                halfWindowMs: halfWindowMs, liftAngleDeg: liftAngleDeg
            )
            if let p = r.pulseMs, let a = r.ampDeg { pulses.append(p); amps.append(a) }
        }
        return PerTickAmps(pulsesMs: pulses, ampsDeg: amps)
    }
    let tickPerTickVac = perTickVacaboja(isEven: true)
    let tockPerTickVac = perTickVacaboja(isEven: false)

    // Per-tick traces: for each candidate, save a downsampled envelope window
    // around the original-argmax center and compute candidate picker positions
    // (centroid vs two onset variants). Used by plot_onsets.py to visualize
    // whether onset is more stable than centroid on multi-sub-event watches.
    func perTickTraces(isEven: Bool, maxCount: Int = 60) -> [PerTickTrace] {
        // Restrict to the highest-SNR candidates so the trace overlay isn't
        // dominated by noisy ticks. SNR-sort then truncate.
        let pool = candidates
            .filter { $0.isEven == isEven }
            .sorted { $0.snr > $1.snr }
            .prefix(maxCount)

        // Onset detection lives on the raw squared signal smoothed at 0.5 ms —
        // tight enough that the onset isn't smeared past the actual rise but
        // wide enough that single-sample noise doesn't trip the threshold.
        let onsetSmoothMs = 0.5
        let onsetSmoothSamples = max(3, Int(onsetSmoothMs / 1000.0 * sampleRate))

        // Display downsample: cap stored envelope at ~600 samples per trace so
        // the JSON stays modest. Half-window is 15 ms = 1323 samples at 44.1k;
        // factor-2 keeps it visually adequate.
        let displayHalfMs: Double = 10.0
        let displayPoints = 400
        let displaySamplePeriodMs = (2.0 * displayHalfMs) / Double(displayPoints)

        // Spectral-flux STFT geometry: window=128 (~2.9ms @44.1k), hop=32
        // (~0.73ms). Frame center for frame f is f*hop + window/2.
        let fftWindow = 128
        let fftHop = 32

        var out: [PerTickTrace] = []
        for c in pool {
            let lo = max(0, c.center - halfWindow)
            let hi = min(filtered.count - 1, c.center + halfWindow)
            guard hi > lo + 4 else { continue }

            // Squared signal in absolute window.
            var sq = [Float](repeating: 0, count: hi - lo + 1)
            for i in 0...(hi - lo) { let v = filtered[lo + i]; sq[i] = v * v }
            let env = movingAvg(sq, window: onsetSmoothSamples)
            let centerLocal = c.center - lo

            // Argmax in env restricted to ±5ms around the candidate center.
            let searchHalf = max(4, Int(0.005 * sampleRate))
            let aLo = max(0, centerLocal - searchHalf)
            let aHi = min(env.count - 1, centerLocal + searchHalf)
            var argIdx = aLo; var argVal: Float = env[aLo]
            for i in aLo...aHi { if env[i] > argVal { argVal = env[i]; argIdx = i } }
            let argmaxMs = Double(argIdx - centerLocal) / sampleRate * 1000.0

            // Centroid (production behavior): centroid of raw squared in ±5ms
            // around argmax. Mirrors `centroid(in:lo:hi:)` minus baseline.
            let cHalfS = max(4, Int(0.005 * sampleRate))
            let cLo = max(0, argIdx - cHalfS)
            let cHi = min(sq.count - 1, argIdx + cHalfS)
            var minVal = sq[cLo]
            for j in (cLo + 1)...cHi { if sq[j] < minVal { minVal = sq[j] } }
            var num: Double = 0; var den: Double = 0
            for j in cLo...cHi {
                let w = Double(sq[j] - minVal)
                if w > 0 { num += w * Double(j); den += w }
            }
            let centroidMs: Double? = den > 0
                ? Double((num / den) - Double(centerLocal)) / sampleRate * 1000.0
                : nil

            // Onset (20% of peak): walk back from argmax until env drops below
            // 20% of the argmax value. Stable on multi-sub-event ticks because
            // it locks to the *first* event regardless of amplitude balance.
            let thresh20 = argVal * 0.20
            var lead20 = argIdx
            while lead20 > 0 && env[lead20 - 1] >= thresh20 { lead20 -= 1 }
            let onset20Ms = Double(lead20 - centerLocal) / sampleRate * 1000.0

            // Onset (baseline + 5σ): estimate quiet baseline from the outer
            // 4 ms of the window, walk back from argmax until env drops below
            // baseline + 5σ for at least 0.1ms continuously.
            let baselineWidthSamples = max(1, Int(0.004 * sampleRate))
            let leftEnd = min(env.count, baselineWidthSamples)
            let rightStart = max(0, env.count - baselineWidthSamples)
            var bAcc: Float = 0; var bN: Int = 0
            for i in 0..<leftEnd { bAcc += env[i]; bN += 1 }
            for i in rightStart..<env.count { bAcc += env[i]; bN += 1 }
            let baseline = bN > 0 ? bAcc / Float(bN) : 0
            var vAcc: Float = 0
            for i in 0..<leftEnd { let d = env[i] - baseline; vAcc += d * d }
            for i in rightStart..<env.count { let d = env[i] - baseline; vAcc += d * d }
            let baseStd = bN > 1 ? sqrt(vAcc / Float(bN)) : 0
            let thresh5 = baseline + 5.0 * baseStd
            let onset5Ms: Double? = {
                guard argVal > thresh5 else { return nil }
                let minRun = max(1, Int(0.0001 * sampleRate))
                var lead = argIdx; var below = 0
                while lead > 0 {
                    if env[lead] < thresh5 { below += 1 } else { below = 0 }
                    if below >= minRun { lead += below; break }
                    lead -= 1
                }
                return Double(lead - centerLocal) / sampleRate * 1000.0
            }()

            // Spectral flux: take a wider raw-signal slice so STFT framing
            // around centerLocal is well-defined, then resample frame
            // centers to the same display grid as env.
            let fluxWindowSamples = Int(0.020 * sampleRate)  // ±20 ms search context
            let fluxLo = max(0, centerLocal - fluxWindowSamples)
            let fluxHi = min(filtered.count - lo, centerLocal + fluxWindowSamples + 1)
            let rawSlice = Array(filtered[(lo + fluxLo)..<min(filtered.count, lo + fluxHi)])
            let fluxArr = spectralFlux(rawSlice, window: fftWindow, hop: fftHop)
            // Frame f is centered at fluxLo + f*fftHop + fftWindow/2 (sample
            // index relative to `env` / centerLocal).
            func fluxAtMs(_ ms: Double) -> Float {
                guard !fluxArr.isEmpty else { return 0 }
                let targetSample = Double(centerLocal) + ms / 1000.0 * sampleRate
                let frameF = (targetSample - Double(fluxLo) - Double(fftWindow / 2)) / Double(fftHop)
                let f0 = Int(floor(frameF))
                let f1 = f0 + 1
                if f0 < 0 || f1 >= fluxArr.count { return 0 }
                let frac = Float(frameF - Double(f0))
                return fluxArr[f0] * (1 - frac) + fluxArr[f1] * frac
            }

            // Downsample env + flux into displayPoints over ±displayHalfMs.
            var dispEnv = [Float](repeating: 0, count: displayPoints)
            var dispFlux = [Float](repeating: 0, count: displayPoints)
            for k in 0..<displayPoints {
                let frac = Double(k) / Double(displayPoints - 1)
                let msFromCenter = -displayHalfMs + frac * (2.0 * displayHalfMs)
                let absIdx = centerLocal + Int(round(msFromCenter / 1000.0 * sampleRate))
                if absIdx >= 0 && absIdx < env.count {
                    dispEnv[k] = env[absIdx]
                }
                dispFlux[k] = fluxAtMs(msFromCenter)
            }

            // Flux peak inside ±10ms of centerLocal — argmax of the flux
            // detection function in the search window. This is the
            // "spectrally onset-like" candidate the picker would use.
            var fluxPeakMs: Double? = nil
            var fluxOnsetMs: Double? = nil
            var fluxFirstMs: Double? = nil
            if !fluxArr.isEmpty {
                let searchHalfMs: Double = 10.0
                let searchHalfSamples = searchHalfMs / 1000.0 * sampleRate
                // Iterate frames whose centers fall in the search window.
                var bestF = -1
                var bestV: Float = 0
                for f in 0..<fluxArr.count {
                    let frameCenterLocal = Double(fluxLo) + Double(f * fftHop + fftWindow / 2)
                    let dist = frameCenterLocal - Double(centerLocal)
                    if abs(dist) <= searchHalfSamples {
                        if fluxArr[f] > bestV { bestV = fluxArr[f]; bestF = f }
                    }
                }
                if bestF >= 0 {
                    // Parabolic interpolation around the peak frame for
                    // sub-frame precision.
                    var peakFrame = Double(bestF)
                    if bestF > 0 && bestF < fluxArr.count - 1 {
                        let y0 = fluxArr[bestF - 1], y1 = fluxArr[bestF], y2 = fluxArr[bestF + 1]
                        let denom = y0 - 2 * y1 + y2
                        if denom != 0 {
                            let r = 0.5 * (y0 - y2) / denom
                            if abs(r) <= 1 { peakFrame = Double(bestF) + Double(r) }
                        }
                    }
                    let peakSampleLocal = Double(fluxLo) + peakFrame * Double(fftHop) + Double(fftWindow / 2)
                    fluxPeakMs = (peakSampleLocal - Double(centerLocal)) / sampleRate * 1000.0

                    // Flux onset: walk backward from peak frame until flux
                    // drops below 50% of peak. Half-peak crossing on a sharp
                    // attack is close to the actual rise, less jittery than
                    // an absolute threshold.
                    let halfPeak = bestV * 0.5
                    var leadF = bestF
                    while leadF > 0 && fluxArr[leadF - 1] >= halfPeak { leadF -= 1 }
                    let leadSampleLocal = Double(fluxLo) + Double(leadF) * Double(fftHop) + Double(fftWindow / 2)
                    fluxOnsetMs = (leadSampleLocal - Double(centerLocal)) / sampleRate * 1000.0

                    // First flux peak above 30% of the window's max flux —
                    // early-stopping search. Walks forward through frames in
                    // the ±10ms search window, finds the first frame that
                    // is a local maximum AND exceeds 30% of bestV. This
                    // locks the picker onto the *first* tick-like sub-event
                    // even when a later sub-event is louder, which is what
                    // makes tick-vs-tock alignment consistent on watches
                    // with multiple sub-clicks per tick.
                    let earlyThresh = bestV * 0.30
                    let searchHalfSamples = 10.0 / 1000.0 * sampleRate
                    var firstF = -1
                    for f in 1..<(fluxArr.count - 1) {
                        let frameCenterLocal = Double(fluxLo) + Double(f * fftHop + fftWindow / 2)
                        let dist = frameCenterLocal - Double(centerLocal)
                        if abs(dist) > searchHalfSamples { continue }
                        if fluxArr[f] >= earlyThresh
                           && fluxArr[f] > fluxArr[f - 1]
                           && fluxArr[f] >= fluxArr[f + 1] {
                            firstF = f
                            break
                        }
                    }
                    if firstF >= 0 {
                        var firstFrame = Double(firstF)
                        if firstF > 0 && firstF < fluxArr.count - 1 {
                            let y0 = fluxArr[firstF - 1], y1 = fluxArr[firstF], y2 = fluxArr[firstF + 1]
                            let denom = y0 - 2 * y1 + y2
                            if denom != 0 {
                                let r = 0.5 * (y0 - y2) / denom
                                if abs(r) <= 1 { firstFrame = Double(firstF) + Double(r) }
                            }
                        }
                        let sampleLocal = Double(fluxLo) + firstFrame * Double(fftHop) + Double(fftWindow / 2)
                        fluxFirstMs = (sampleLocal - Double(centerLocal)) / sampleRate * 1000.0
                    }
                }
            }

            out.append(PerTickTrace(
                beatIndex: c.beatIndex, isEven: c.isEven,
                centerSampleAbs: c.center,
                envSamples: dispEnv,
                fluxSamples: dispFlux,
                envSampleRate: 1000.0 / displaySamplePeriodMs,
                envHalfMs: displayHalfMs,
                argmaxMs: argmaxMs,
                centroidMs: centroidMs,
                onsetMs20pct: onset20Ms,
                onsetMs5sigma: onset5Ms,
                fluxPeakMs: fluxPeakMs,
                fluxOnsetMs: fluxOnsetMs,
                fluxFirstMs: fluxFirstMs,
                matchedMs: nil
            ))
        }
        return out
    }
    var tickTraces = perTickTraces(isEven: true)
    var tockTraces = perTickTraces(isEven: false)

    // Matched-filter refinement, centroid-bootstrapped + iterated.
    //
    // Pass 0 aligns each trace to its centroid (class-unbiased reference)
    // and builds a shared template from all traces. Subsequent passes use
    // the previous pass's matched-filter offset as the alignment reference,
    // sharpening the template each round. Convergence: stop when the max
    // per-tick offset change is < 0.01 ms or the iteration cap is reached.
    //
    // Cost is bounded — each pass is two array shifts + one cross-correlation
    // per tick (≈ 90 ticks × 400 samples × 80 lags ≈ 3M float ops per pass).
    // We cap at 5 iterations and report the wall-clock cost so we can budget
    // it for the production pipeline.
    let mfStart = Date()
    var mfIters = 0
    do {
        let maxIters = 5
        let convergeMs = 0.01
        for iter in 0..<maxIters {
            let getOffset: (PerTickTrace) -> Double? = iter == 0
                ? { $0.centroidMs }
                : { $0.matchedMs }
            let template = buildAlignedTemplate(tickTraces + tockTraces, offsetMs: getOffset)
            let prevTick = tickTraces, prevTock = tockTraces
            tickTraces = matchedFilterPass(tickTraces, template: template, offsetMs: getOffset)
            tockTraces = matchedFilterPass(tockTraces, template: template, offsetMs: getOffset)
            mfIters = iter + 1
            var maxDelta = 0.0
            for (a, b) in zip(prevTick + prevTock, tickTraces + tockTraces) {
                let prev = (iter == 0 ? a.centroidMs : a.matchedMs) ?? 0
                let curr = b.matchedMs ?? prev
                maxDelta = max(maxDelta, abs(curr - prev))
            }
            if maxDelta < convergeMs { break }
        }
    }

    // 1.5σ iterated class-wise trimming. After matched-filter convergence,
    // joint-regress matched_ms positions, compute per-class residuals, and
    // null matched_ms on ticks more than 1.5σ from the per-class mean. Re-fit
    // on survivors; iterate until stable. The 1.5σ threshold cracks bimodal
    // distributions that 2σ misses (when σ is inflated by the bimodality
    // itself) while preserving 50%+ of ticks across the OmegaStudy corpus.
    let trimK = 1.5
    let trimIters = 4
    let allTracesPostMF = tickTraces + tockTraces
    var keptFlags = [Bool](repeating: true, count: allTracesPostMF.count)
    for _ in 0..<trimIters {
        var n = 0
        var meanBi = 0.0, meanPos = 0.0
        var positions = [Double](repeating: 0, count: allTracesPostMF.count)
        for (i, t) in allTracesPostMF.enumerated() {
            guard keptFlags[i], let m = t.matchedMs else { continue }
            positions[i] = Double(t.centerSampleAbs) / sampleRate * 1000.0 + m
            meanBi += Double(t.beatIndex); meanPos += positions[i]; n += 1
        }
        guard n >= 4 else { break }
        meanBi /= Double(n); meanPos /= Double(n)
        var sxx = 0.0, sxy = 0.0
        for (i, t) in allTracesPostMF.enumerated() where keptFlags[i] && t.matchedMs != nil {
            let dx = Double(t.beatIndex) - meanBi
            let dy = positions[i] - meanPos
            sxx += dx * dx; sxy += dx * dy
        }
        let slope = sxx > 0 ? sxy / sxx : 0
        let intercept = meanPos - slope * meanBi
        var sumE = 0.0, sumO = 0.0; var ne = 0, no = 0
        var residuals = [Double](repeating: 0, count: allTracesPostMF.count)
        for (i, t) in allTracesPostMF.enumerated() where keptFlags[i] && t.matchedMs != nil {
            residuals[i] = positions[i] - (slope * Double(t.beatIndex) + intercept)
            if t.isEven { sumE += residuals[i]; ne += 1 } else { sumO += residuals[i]; no += 1 }
        }
        let muE = ne > 0 ? sumE / Double(ne) : 0
        let muO = no > 0 ? sumO / Double(no) : 0
        var ssE = 0.0, ssO = 0.0
        for (i, t) in allTracesPostMF.enumerated() where keptFlags[i] && t.matchedMs != nil {
            let mu = t.isEven ? muE : muO
            let d = residuals[i] - mu
            if t.isEven { ssE += d * d } else { ssO += d * d }
        }
        let sdE = ne > 1 ? sqrt(ssE / Double(ne)) : 0
        let sdO = no > 1 ? sqrt(ssO / Double(no)) : 0
        var changed = false
        for (i, t) in allTracesPostMF.enumerated() where keptFlags[i] && t.matchedMs != nil {
            let mu = t.isEven ? muE : muO
            let sd = t.isEven ? sdE : sdO
            if sd > 0 && abs(residuals[i] - mu) > trimK * sd {
                keptFlags[i] = false; changed = true
            }
        }
        if !changed { break }
    }
    // Apply the trim by nulling matched_ms on dropped traces. Plot and
    // BE diagnostic both already skip nil matched_ms.
    var trimTickDropped = 0, trimTockDropped = 0
    func nulled(_ t: PerTickTrace) -> PerTickTrace {
        return PerTickTrace(beatIndex: t.beatIndex, isEven: t.isEven,
            centerSampleAbs: t.centerSampleAbs, envSamples: t.envSamples,
            fluxSamples: t.fluxSamples, envSampleRate: t.envSampleRate,
            envHalfMs: t.envHalfMs, argmaxMs: t.argmaxMs,
            centroidMs: t.centroidMs, onsetMs20pct: t.onsetMs20pct,
            onsetMs5sigma: t.onsetMs5sigma, fluxPeakMs: t.fluxPeakMs,
            fluxOnsetMs: t.fluxOnsetMs, fluxFirstMs: t.fluxFirstMs,
            matchedMs: nil)
    }
    for i in 0..<tickTraces.count where !keptFlags[i] {
        tickTraces[i] = nulled(tickTraces[i]); trimTickDropped += 1
    }
    let tockBase = tickTraces.count
    for j in 0..<tockTraces.count where !keptFlags[tockBase + j] {
        tockTraces[j] = nulled(tockTraces[j]); trimTockDropped += 1
    }

    let mfElapsedMs = Date().timeIntervalSince(mfStart) * 1000
    let logLine = "matched-filter: \(mfIters) iters + 1.5σ trim, "
        + "dropped tick=\(trimTickDropped)/\(tickTraces.count) "
        + "tock=\(trimTockDropped)/\(tockTraces.count), "
        + "\(String(format: "%.1f", mfElapsedMs))ms\n"
    FileHandle.standardError.write(logLine.data(using: .utf8)!)

    return AnatomyResult(
        filename: url.lastPathComponent,
        sampleRate: sampleRate,
        beatPeriod: beatPeriod,
        snappedBph: result.snappedRate.rawValue,
        quality: Int(result.qualityScore * 100),
        tickAvg: tickAvg,
        tockAvg: tockAvg,
        tickPerTick: tickPerTick,
        tockPerTick: tockPerTick,
        tickPerTick3: tickPerTick3,
        tockPerTick3: tockPerTick3,
        tickPerTickVac: tickPerTickVac,
        tockPerTickVac: tockPerTickVac,
        tickTraces: tickTraces,
        tockTraces: tockTraces
    )
}

// MARK: - Visualization

/// Find local maxima in an envelope that are at least `prominence` fraction of
/// the global max and at least `minSeparationMs` apart. Returns (timeMs, amplitudeRatio).
func detectPeaks(
    _ env: [Float], sampleRate: Double, prominence: Float = 0.15, minSeparationMs: Double = 1.0
) -> [(timeMs: Double, amp: Float)] {
    let n = env.count
    guard n > 4 else { return [] }
    let half = n / 2
    let globalMax = env.max() ?? 0
    guard globalMax > 0 else { return [] }
    let threshold = globalMax * prominence
    let minSepSamples = Int(minSeparationMs / 1000.0 * sampleRate)

    var peaks: [(Int, Float)] = []
    for i in 2..<(n - 2) {
        let v = env[i]
        if v < threshold { continue }
        if v >= env[i - 1] && v >= env[i - 2] && v >= env[i + 1] && v >= env[i + 2] {
            peaks.append((i, v))
        }
    }

    // Sort by amplitude desc, keep only peaks with enough separation from earlier-kept peaks.
    peaks.sort { $0.1 > $1.1 }
    var kept: [(Int, Float)] = []
    for p in peaks {
        if kept.allSatisfy({ abs($0.0 - p.0) >= minSepSamples }) {
            kept.append(p)
        }
    }
    // Return in time order.
    kept.sort { $0.0 < $1.0 }
    return kept.map { (Double($0.0 - half) / sampleRate * 1000.0, $0.1 / globalMax) }
}

/// Render an envelope as a single-row ASCII strip. `columns` characters across
/// the full window. Amplitude mapped to a density glyph.
func renderStrip(_ env: [Float], columns: Int = 80) -> String {
    let n = env.count
    guard n > 0 else { return "" }
    let maxV = env.max() ?? 0
    guard maxV > 0 else { return String(repeating: " ", count: columns) }
    let glyphs: [Character] = [" ", ".", ":", "-", "=", "+", "*", "#", "@"]
    var out = ""
    out.reserveCapacity(columns)
    for c in 0..<columns {
        // Average all samples falling into this column.
        let lo = c * n / columns
        let hi = max(lo + 1, (c + 1) * n / columns)
        var s: Float = 0
        for i in lo..<min(hi, n) { s += env[i] }
        let avg = s / Float(hi - lo)
        let frac = min(1, max(0, avg / maxV))
        let idx = min(glyphs.count - 1, Int(frac * Float(glyphs.count - 1) + 0.5))
        out.append(glyphs[idx])
    }
    return out
}

/// Escapement phases: unlock (pallet releases from escape wheel), impulse
/// (escape wheel pushes pallet), drop (next tooth lands). The fine envelope of
/// a coherently-averaged tick typically shows up to three peaks; the span from
/// first (unlock) to last (drop) is the balance-wheel lift pulse and is what
/// the amplitude formula expects.
struct ThreePhase {
    /// Up to three peaks in time order.
    let peaks: [(timeMs: Double, amp: Float)]
    var unlock: (timeMs: Double, amp: Float)? { peaks.count >= 1 ? peaks[0] : nil }
    var impulse: (timeMs: Double, amp: Float)? { peaks.count >= 3 ? peaks[1] : nil }
    var drop: (timeMs: Double, amp: Float)? { peaks.count >= 3 ? peaks[2] : (peaks.count == 2 ? peaks[1] : nil) }
    /// Span from first to last peak, or nil if we only found one.
    var spanMs: Double? {
        guard peaks.count >= 2 else { return nil }
        return peaks.last!.timeMs - peaks.first!.timeMs
    }
}

/// Find up to three prominent peaks in the averaged envelope. Takes the three
/// highest-amplitude peaks above a modest prominence floor with at least
/// 0.5 ms separation, then returns them in time order.
func detectThreePhases(_ env: [Float], sampleRate: Double) -> ThreePhase {
    let peaks = detectPeaks(env, sampleRate: sampleRate, prominence: 0.12, minSeparationMs: 0.5)
    let topByAmp = Array(peaks.sorted { $0.amp > $1.amp }.prefix(3))
    let inTime = topByAmp.sorted { $0.timeMs < $1.timeMs }
    return ThreePhase(peaks: inTime)
}

/// Envelope pulse width at a fixed fraction of peak. Walks outward from the
/// peak so dips in sub-structure don't truncate the measurement. Low threshold
/// (10%) captures the full audible burst including quiet unlock/drop edges.
struct PulseWidth {
    let leadIdx: Int
    let trailIdx: Int
    let peakIdx: Int
    let leadMs: Double
    let trailMs: Double
    let widthMs: Double
}

func measurePulseWidth(
    _ env: [Float], sampleRate: Double, halfWindowMs: Double, thresholdFraction: Float = 0.10
) -> PulseWidth? {
    let n = env.count
    guard n > 4 else { return nil }
    var peakIdx = 0
    var peakVal: Float = 0
    for i in 0..<n { if env[i] > peakVal { peakVal = env[i]; peakIdx = i } }
    guard peakVal > 0 else { return nil }
    let thresh = thresholdFraction * peakVal

    var lead = peakIdx
    while lead > 0 && env[lead - 1] >= thresh { lead -= 1 }
    var trail = peakIdx
    while trail < n - 1 && env[trail + 1] >= thresh { trail += 1 }

    let half = n / 2
    let leadMs = Double(lead - half) / sampleRate * 1000.0
    let trailMs = Double(trail - half) / sampleRate * 1000.0
    return PulseWidth(
        leadIdx: lead, trailIdx: trail, peakIdx: peakIdx,
        leadMs: leadMs, trailMs: trailMs, widthMs: trailMs - leadMs
    )
}

/// Onset-based lift pulse: the first and last moments at which tick power
/// rises clearly above the pre-tick noise floor. This is what a professional
/// timegrapher hears — the *edges* of audibility, not the peaks.
///
/// Coherent averaging crushes the noise floor by √N (on the Omega, ~9.5×) so
/// we can set the detection threshold at a small multiple of baseline RMS
/// instead of a fraction of peak. That exposes the quiet unlock onset and the
/// long drop tail that fixed-fraction thresholds clip off.
struct OnsetPulse {
    let leadMs: Double
    let trailMs: Double
    let widthMs: Double
    let baselinePower: Float
    let thresholdMultiple: Float
}

/// `baselineHalfMs` defines a "quiet" interval on each side of the window used
/// to estimate the noise floor. `kSigma` is the multiple of baseline RMS that
/// counts as "tick present".
func measureOnsetPulse(
    _ waveform: [Float], sampleRate: Double, halfWindowMs: Double,
    baselineHalfMs: Double = 5.0, kSigma: Float = 5.0, minContiguousMs: Double = 0.1
) -> OnsetPulse? {
    let n = waveform.count
    guard n > 20 else { return nil }
    let half = n / 2

    // Power (squared amplitude) — cleaner edges than rectified amplitude.
    var power = [Float](repeating: 0, count: n)
    for i in 0..<n { power[i] = waveform[i] * waveform[i] }
    // Light smoothing (0.3 ms) so single-sample noise spikes don't flip the
    // threshold. Keeps edges sharper than the 3ms pulse-width smoothing.
    let smoothSamples = max(3, Int(0.0003 * sampleRate))
    let smooth = movingAvg(power, window: smoothSamples)

    // Baseline power from far-from-center samples on both ends.
    let baselineSamples = Int(baselineHalfMs / 1000.0 * sampleRate)
    let leftEnd = max(0, half - Int(halfWindowMs / 1000.0 * sampleRate) + baselineSamples)
    let rightStart = min(n, half + Int(halfWindowMs / 1000.0 * sampleRate) - baselineSamples)
    guard leftEnd < half, rightStart > half, leftEnd > 0, rightStart < n else { return nil }
    var bAcc: Float = 0
    var bCount = 0
    for i in 0..<leftEnd { bAcc += smooth[i]; bCount += 1 }
    for i in rightStart..<n { bAcc += smooth[i]; bCount += 1 }
    guard bCount > 0 else { return nil }
    let baseline = bAcc / Float(bCount)
    // Estimate baseline variance so kSigma is in units of actual noise.
    var varAcc: Float = 0
    for i in 0..<leftEnd { let d = smooth[i] - baseline; varAcc += d * d }
    for i in rightStart..<n { let d = smooth[i] - baseline; varAcc += d * d }
    let baselineStd = sqrt(varAcc / Float(bCount))
    let threshold = baseline + kSigma * baselineStd

    // Require `minContiguousMs` of continuous above-threshold to count as
    // pulse — rejects solitary spikes that slip through smoothing.
    let minRun = max(1, Int(minContiguousMs / 1000.0 * sampleRate))
    // Find the absolute peak first, then walk outward until we've been below
    // threshold for minRun contiguous samples.
    var peakIdx = 0; var peakVal: Float = 0
    for i in 0..<n { if smooth[i] > peakVal { peakVal = smooth[i]; peakIdx = i } }
    guard peakVal > threshold else { return nil }

    var lead = peakIdx
    var belowRun = 0
    while lead > 0 {
        if smooth[lead] < threshold { belowRun += 1 } else { belowRun = 0 }
        if belowRun >= minRun { lead += belowRun; break }
        lead -= 1
    }
    var trail = peakIdx
    belowRun = 0
    while trail < n - 1 {
        if smooth[trail] < threshold { belowRun += 1 } else { belowRun = 0 }
        if belowRun >= minRun { trail -= belowRun; break }
        trail += 1
    }

    let leadMs = Double(lead - half) / sampleRate * 1000.0
    let trailMs = Double(trail - half) / sampleRate * 1000.0
    return OnsetPulse(
        leadMs: leadMs, trailMs: trailMs, widthMs: trailMs - leadMs,
        baselinePower: baseline, thresholdMultiple: kSigma
    )
}

/// Render an ASCII strip with phase labels ('1'/'2'/'3') at peak columns and
/// `[` / `]` at the pulse-width edges.
func renderStripOverlay(
    _ env: [Float], phases: ThreePhase, pulse: PulseWidth?, halfWindowMs: Double, columns: Int = 80
) -> String {
    let base = renderStrip(env, columns: columns)
    var chars = Array(base)
    func colFor(ms: Double) -> Int {
        let frac = (ms + halfWindowMs) / (2 * halfWindowMs)
        return min(columns - 1, max(0, Int(frac * Double(columns))))
    }
    if let p = pulse {
        chars[colFor(ms: p.leadMs)] = "["
        chars[colFor(ms: p.trailMs)] = "]"
    }
    for (i, peak) in phases.peaks.enumerated() {
        chars[colFor(ms: peak.timeMs)] = Character(String(i + 1))
    }
    return String(chars)
}

// MARK: - vacaboja/tg reference implementation
//
// Straight port of the amplitude algorithm published in vacaboja/tg
// (https://github.com/vacaboja/tg, src/algo.c), for apples-to-apples comparison
// against our own fold+mean-smooth pipeline. Two components:
//
//   1. `vacabojaSmooth`: the `smooth()` function from algo.c:611. It is a leaky
//      peak-hold followed by a box-mean, both using a 1 ms window. This is
//      materially different from an abs-value mean lowpass — peak-hold preserves
//      peak height, so a fixed "% of peak" threshold means something different
//      than it does on a mean-smoothed envelope.
//
//   2. `vacabojaFindPulse` + `vacabojaAmplitude`: the `compute_amplitude()`
//      function from algo.c:745. The threshold is not fixed at 20%. It sweeps
//      upward from `max(1% · glob_max, 1.4 · noise_level)` by factors of 1.4
//      until both tick and tock pulses give amplitudes in [135°, 360°] with
//      |tick − tock| < 60°. The 20% threshold is the upper bound for the sweep,
//      not the starting point.
//
// Window choices that are ours, not vacaboja's: we apply the algorithm to our
// coherent-averaged tick/tock waveforms (which are ±15 ms windows per class)
// rather than to a period-long folded waveform containing both. We search for
// the first peak within `min(period/8, 13 ms)` before the anchor (tick center,
// which is the lock click in our alignment), matching the intent of vacaboja's
// period/8 search range.

/// Peak-hold + box-mean envelope. Faithful to vacaboja/tg src/algo.c:611.
/// `window` is in samples; the published value is `sample_rate / 1000` (1 ms).
func vacabojaSmooth(_ signal: [Float], window: Int) -> [Float] {
    let n = signal.count
    guard window > 1, n > window else { return signal }
    var out = [Float](repeating: 0, count: n)
    let k = 1.0 - 1.0 / Double(window)
    var u: Double = 0
    var rAv: Double = 0
    for i in 0..<window {
        u *= k
        let x = Double(signal[i])
        if x > u { u = x }
        rAv += u
    }
    var w: Double = 0
    let limit = n - window
    for i in 0..<limit {
        out[i] = Float(rAv)
        u *= k
        w *= k
        let xNew = Double(signal[i + window])
        let xOld = Double(signal[i])
        if xNew > u { u = xNew }
        if xOld > w { w = xOld }
        rAv += u - w
    }
    // Pad trailing region with the last valid value so indexing stays uniform.
    let last = out[limit - 1]
    for i in limit..<n { out[i] = last }
    return out
}

/// Walk forward from (anchor - searchSamples) toward `anchor`. Return the
/// sample distance from the first rising-peak-above-threshold back to `anchor`,
/// or nil if no such peak exists in the window. Faithful to vacaboja's inner
/// loops in src/algo.c:774-794.
func vacabojaFindPulse(
    envelope env: [Float], anchor: Int, searchSamples: Int, threshold: Float
) -> Int? {
    let n = env.count
    guard anchor > 0, anchor < n else { return nil }
    let start = max(0, anchor - searchSamples)
    var j = start
    while j < anchor && env[j] <= threshold { j += 1 }
    guard j < anchor else { return nil }
    var peakIdx = j
    var peakVal = env[j]
    j += 1
    while j <= anchor {
        if env[j] > peakVal { peakVal = env[j]; peakIdx = j; j += 1 }
        else { break }
    }
    let dist = anchor - peakIdx
    return dist > 0 ? dist : nil
}

/// Result of running vacaboja's threshold sweep on a single window (one tick
/// or one class average). `nil` fields mean the sweep didn't converge — the
/// caller should discard or count this tick as failed.
struct VacabojaSingle {
    let pulseMs: Double?
    let ampDeg: Double?
    let thresholdPctOfGlobMax: Double?
}

/// Run vacaboja's pulse-finding and threshold sweep on a single window.
/// Returns a pulse+amp pair from the first threshold producing an amplitude
/// in [135°, 360°], or nil if the sweep exhausted without convergence.
/// `noiseMaxOverride` lets the caller supply a noise floor computed over a
/// larger corpus (e.g. the "quiet tails" of many ticks); if nil, noise is
/// taken as the max of `env` outside the `noiseCoreHalfMs` core around anchor.
func vacabojaSingle(
    waveform: [Float], sampleRate: Double, beatPeriodSec: Double,
    halfWindowMs: Double, liftAngleDeg: Double,
    noiseMaxOverride: Float? = nil
) -> VacabojaSingle {
    let window = max(3, Int(0.001 * sampleRate))
    var rect = [Float](repeating: 0, count: waveform.count)
    vDSP_vabs(waveform, 1, &rect, 1, vDSP_Length(waveform.count))
    let env = vacabojaSmooth(rect, window: window)
    var anchor = 0
    var globMax: Float = 0
    for i in 0..<env.count { if env[i] > globMax { globMax = env[i]; anchor = i } }
    guard globMax > 0 else {
        return VacabojaSingle(pulseMs: nil, ampDeg: nil, thresholdPctOfGlobMax: nil)
    }
    let noiseMax: Float = {
        if let o = noiseMaxOverride { return o }
        let coreHalf = Int((halfWindowMs - 4.0) / 1000.0 * sampleRate)
        let lo = max(0, anchor - coreHalf)
        let hi = min(env.count, anchor + coreHalf + 1)
        var m: Float = 0
        for i in 0..<lo { if env[i] > m { m = env[i] } }
        for i in hi..<env.count { if env[i] > m { m = env[i] } }
        return m
    }()
    let searchSamples = min(
        Int(beatPeriodSec / 8 * sampleRate),
        Int((halfWindowMs - 1) / 1000.0 * sampleRate)
    )
    var threshold = Float(max(0.01 * Double(globMax), 1.4 * Double(noiseMax)))
    let cap = Float(0.2 * Double(globMax))
    while threshold < cap {
        if let dist = vacabojaFindPulse(
            envelope: env, anchor: anchor,
            searchSamples: searchSamples, threshold: threshold) {
            let pulseMs = Double(dist) / sampleRate * 1000.0
            if let amp = AmplitudeEstimator.amplitude(
                pulseMs: pulseMs, beatPeriodSeconds: beatPeriodSec, liftAngleDegrees: liftAngleDeg) {
                return VacabojaSingle(
                    pulseMs: pulseMs, ampDeg: amp,
                    thresholdPctOfGlobMax: Double(threshold) / Double(globMax) * 100.0
                )
            }
        }
        threshold *= 1.4
    }
    return VacabojaSingle(pulseMs: nil, ampDeg: nil, thresholdPctOfGlobMax: nil)
}

struct VacabojaAmplitude {
    let tickPulseMs: Double?
    let tockPulseMs: Double?
    let tickAmpDeg: Double?
    let tockAmpDeg: Double?
    let combinedAmpDeg: Double?
    let thresholdPctOfGlobMax: Double?
}

/// Full vacaboja amplitude computation: peak-hold+box-mean 1 ms envelopes on
/// tick and tock waveforms, threshold-sweep from noise floor to 20% of global
/// max, accept first threshold producing both amps in [135°, 360°] with
/// |tick − tock| < 60°. See src/algo.c:745-812.
func vacabojaAmplitude(
    tickWf: [Float]?, tockWf: [Float]?, sampleRate: Double,
    beatPeriodSec: Double, halfWindowMs: Double, liftAngleDeg: Double
) -> VacabojaAmplitude {
    let nothing = VacabojaAmplitude(
        tickPulseMs: nil, tockPulseMs: nil,
        tickAmpDeg: nil, tockAmpDeg: nil,
        combinedAmpDeg: nil, thresholdPctOfGlobMax: nil
    )
    guard let tickWf = tickWf, let tockWf = tockWf else { return nothing }
    let window = max(3, Int(0.001 * sampleRate))
    // Peak-hold envelope is taken on the rectified waveform; vacaboja's input is
    // also rectified (it operates on `p->waveform` which has been abs'd upstream).
    func rectified(_ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vabs(x, 1, &out, 1, vDSP_Length(x.count))
        return out
    }
    let tickEnv = vacabojaSmooth(rectified(tickWf), window: window)
    let tockEnv = vacabojaSmooth(rectified(tockWf), window: window)
    func argmax(_ env: [Float]) -> (idx: Int, val: Float) {
        var idx = 0; var val: Float = 0
        for i in 0..<env.count { if env[i] > val { val = env[i]; idx = i } }
        return (idx, val)
    }
    let (tickAnchor, tickMax) = argmax(tickEnv)
    let (tockAnchor, tockMax) = argmax(tockEnv)
    let globMax = max(tickMax, tockMax)
    guard globMax > 0 else { return nothing }

    // Noise floor: max of envelope outside a ±halfWindow-4ms core around anchor.
    // vacaboja samples "noise" from the far side of the period from the anchor;
    // we don't have that in our per-class frames, so we take the outer 4 ms of
    // the window as the quiet proxy.
    func outerMax(_ env: [Float], anchor: Int, coreHalfSamples: Int) -> Float {
        let n = env.count
        let lo = max(0, anchor - coreHalfSamples)
        let hi = min(n, anchor + coreHalfSamples + 1)
        var m: Float = 0
        for i in 0..<lo { if env[i] > m { m = env[i] } }
        for i in hi..<n { if env[i] > m { m = env[i] } }
        return m
    }
    let coreHalf = Int((halfWindowMs - 4.0) / 1000.0 * sampleRate)
    let noiseMax = max(
        outerMax(tickEnv, anchor: tickAnchor, coreHalfSamples: coreHalf),
        outerMax(tockEnv, anchor: tockAnchor, coreHalfSamples: coreHalf)
    )

    // Search range: min(period/8, halfWindow - 1 ms to leave margin at start).
    let periodSamples = beatPeriodSec * sampleRate
    let searchSamples = min(Int(periodSamples / 8), Int((halfWindowMs - 1) / 1000.0 * sampleRate))

    var threshold = Float(max(0.01 * Double(globMax), 1.4 * Double(noiseMax)))
    let thresholdCap = Float(0.2 * Double(globMax))

    while threshold < thresholdCap {
        if let tickDist = vacabojaFindPulse(
               envelope: tickEnv, anchor: tickAnchor,
               searchSamples: searchSamples, threshold: threshold),
           let tockDist = vacabojaFindPulse(
               envelope: tockEnv, anchor: tockAnchor,
               searchSamples: searchSamples, threshold: threshold) {
            let tickMs = Double(tickDist) / sampleRate * 1000.0
            let tockMs = Double(tockDist) / sampleRate * 1000.0
            let tickAmp = AmplitudeEstimator.amplitude(
                pulseMs: tickMs, beatPeriodSeconds: beatPeriodSec, liftAngleDegrees: liftAngleDeg)
            let tockAmp = AmplitudeEstimator.amplitude(
                pulseMs: tockMs, beatPeriodSeconds: beatPeriodSec, liftAngleDegrees: liftAngleDeg)
            if let a = tickAmp, let b = tockAmp, abs(a - b) < 60 {
                return VacabojaAmplitude(
                    tickPulseMs: tickMs, tockPulseMs: tockMs,
                    tickAmpDeg: a, tockAmpDeg: b, combinedAmpDeg: (a + b) / 2,
                    thresholdPctOfGlobMax: Double(threshold) / Double(globMax) * 100.0
                )
            }
        }
        threshold *= 1.4
    }
    return nothing
}

/// Axis labels aligned with an 80-column strip centered on 0 ms.
func axisLabels(halfWindowMs: Double, columns: Int = 80) -> String {
    // Marks at -halfWindow, -halfWindow/2, 0, +halfWindow/2, +halfWindow.
    var line = Array(repeating: Character(" "), count: columns)
    let positions = [0, columns / 4, columns / 2, 3 * columns / 4, columns - 1]
    let values = [-halfWindowMs, -halfWindowMs / 2, 0.0, halfWindowMs / 2, halfWindowMs]
    for (p, v) in zip(positions, values) {
        let label = String(format: "%.0f", v)
        let start = max(0, min(columns - label.count, p - label.count / 2))
        for (i, ch) in label.enumerated() where start + i < columns {
            line[start + i] = ch
        }
    }
    return String(line) + "  ms"
}

func ampFrom(_ widthMs: Double?, beatPeriodSec: Double, liftAngleDeg: Double) -> Double? {
    guard let w = widthMs else { return nil }
    return AmplitudeEstimator.amplitude(
        pulseMs: w, beatPeriodSeconds: beatPeriodSec, liftAngleDegrees: liftAngleDeg
    )
}

func fmtAmp(_ a: Double?) -> String { a.map { String(format: "%.0f°", $0) } ?? "out-of-range" }

/// Prints the envelope strip plus two lines of metrics: three-phase peaks with
/// their span-based amplitude, and low-threshold pulse width with its
/// span-based amplitude. Returns the pulse-width amplitude (the one most likely
/// to be physically plausible on healthy watches); the phase-span one is shown
/// so we can see how it compares.
/// Everything we detected for one class, in a shape easy to serialize as JSON
/// for the plot script to overlay.
struct ClassMeasurements {
    let phasePeaksMs: [Double]
    let phaseAmpsRel: [Float]
    let phaseAmp: Double?
    // Pulse width at 20% threshold at 1ms smoothing.
    let midLeadMs: Double?
    let midTrailMs: Double?
    let midAmp: Double?
    // Pulse width at 20% threshold at 3ms smoothing (matches AmplitudeEstimator).
    let pulseLeadMs: Double?
    let pulseTrailMs: Double?
    let pulseAmp: Double?
    let onsetLeadMs: Double?
    let onsetTrailMs: Double?
    let onsetAmp: Double?
}

func printAscii(
    title: String, waveform: [Float], fineEnv: [Float], midEnv: [Float], pulseEnv: [Float],
    halfWindowMs: Double, sampleRate: Double,
    beatPeriodSec: Double, liftAngleDeg: Double
) -> (phaseAmp: Double?, midAmp: Double?, pulseAmp: Double?, onsetAmp: Double?, measurements: ClassMeasurements) {
    print(title)
    let phases = detectThreePhases(fineEnv, sampleRate: sampleRate)
    let mid = measurePulseWidth(midEnv, sampleRate: sampleRate, halfWindowMs: halfWindowMs, thresholdFraction: 0.20)
    let pulse = measurePulseWidth(pulseEnv, sampleRate: sampleRate, halfWindowMs: halfWindowMs, thresholdFraction: 0.20)
    let onset = measureOnsetPulse(waveform, sampleRate: sampleRate, halfWindowMs: halfWindowMs)
    let strip = renderStripOverlay(fineEnv, phases: phases, pulse: mid, halfWindowMs: halfWindowMs, columns: 80)
    print("  |" + strip + "|")
    print("   " + axisLabels(halfWindowMs: halfWindowMs))

    let phaseStr = phases.peaks.enumerated().map { i, p in
        String(format: "%d@%+.2fms(%.0f%%)", i + 1, p.timeMs, p.amp * 100)
    }.joined(separator: "  ")
    let phaseAmp = ampFrom(phases.spanMs, beatPeriodSec: beatPeriodSec, liftAngleDeg: liftAngleDeg)
    let phaseSpanStr = phases.spanMs.map { String(format: "%.2fms", $0) } ?? "-"
    print("  phases: \(phaseStr.isEmpty ? "-" : phaseStr)   span=\(phaseSpanStr)   amp=\(fmtAmp(phaseAmp))")

    let midAmp = ampFrom(mid?.widthMs, beatPeriodSec: beatPeriodSec, liftAngleDeg: liftAngleDeg)
    if let m = mid {
        print(String(format: "  1ms env: [%+.2fms … %+.2fms]           width=%.2fms   amp=%@",
                     m.leadMs, m.trailMs, m.widthMs, fmtAmp(midAmp)))
    } else {
        print("  1ms env: -")
    }

    let pulseAmp = ampFrom(pulse?.widthMs, beatPeriodSec: beatPeriodSec, liftAngleDeg: liftAngleDeg)
    if let p = pulse {
        print(String(format: "  3ms env: [%+.2fms … %+.2fms]           width=%.2fms   amp=%@",
                     p.leadMs, p.trailMs, p.widthMs, fmtAmp(pulseAmp)))
    } else {
        print("  3ms env: -")
    }

    let onsetAmp = ampFrom(onset?.widthMs, beatPeriodSec: beatPeriodSec, liftAngleDeg: liftAngleDeg)
    if let o = onset {
        print(String(format: "  onset:   [%+.2fms … %+.2fms]           width=%.2fms   amp=%@   (k=%.1fσ)",
                     o.leadMs, o.trailMs, o.widthMs, fmtAmp(onsetAmp), o.thresholdMultiple))
    } else {
        print("  onset:   -")
    }
    let measurements = ClassMeasurements(
        phasePeaksMs: phases.peaks.map { $0.timeMs },
        phaseAmpsRel: phases.peaks.map { $0.amp },
        phaseAmp: phaseAmp,
        midLeadMs: mid?.leadMs, midTrailMs: mid?.trailMs, midAmp: midAmp,
        pulseLeadMs: pulse?.leadMs, pulseTrailMs: pulse?.trailMs, pulseAmp: pulseAmp,
        onsetLeadMs: onset?.leadMs, onsetTrailMs: onset?.trailMs, onsetAmp: onsetAmp
    )
    return (phaseAmp, midAmp, pulseAmp, onsetAmp, measurements)
}

// MARK: - Output

func medianSnr(_ v: [Float]) -> Float {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted()
    return s[s.count / 2]
}

func writeCsv(_ anatomy: AnatomyResult) {
    let sampleRate = anatomy.sampleRate
    let tick = anatomy.tickAvg
    let tock = anatomy.tockAvg
    let length = tick?.waveform.count ?? tock?.waveform.count ?? 0
    guard length > 0 else { return }

    let halfIdx = length / 2
    let csvName = (anatomy.filename as NSString).deletingPathExtension + ".anatomy.csv"

    var lines: [String] = []
    lines.append("time_ms,tick_waveform,tock_waveform,tick_env_fine,tock_env_fine,tick_env_mid,tock_env_mid,tick_env_pulse,tock_env_pulse")

    for i in 0..<length {
        let timeMs = Double(i - halfIdx) / sampleRate * 1000.0
        let tw = tick?.waveform[i] ?? 0
        let kw = tock?.waveform[i] ?? 0
        let tef = tick?.envelope[i] ?? 0
        let kef = tock?.envelope[i] ?? 0
        let tem = tick?.midEnvelope[i] ?? 0
        let kem = tock?.midEnvelope[i] ?? 0
        let tep = tick?.pulseEnvelope[i] ?? 0
        let kep = tock?.pulseEnvelope[i] ?? 0
        lines.append(String(format: "%.4f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f", timeMs, tw, kw, tef, kef, tem, kem, tep, kep))
    }

    let url = URL(fileURLWithPath: csvName)
    try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    FileHandle.standardError.write("wrote \(csvName)\n".data(using: .utf8)!)
}

func perTickBlock(_ p: PerTickWidths?) -> String {
    guard let p = p, p.count > 0 else { return "null" }
    let widths = "[" + p.widthsMs.map { String(format: "%.4f", $0) }.joined(separator: ",") + "]"
    func f(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "null" }
    return """
    {
        "widths_ms": \(widths),
        "n": \(p.count),
        "median_ms": \(f(p.median)),
        "mean_ms": \(f(p.mean)),
        "std_ms": \(f(p.std)),
        "p25_ms": \(f(p.percentile(25))),
        "p75_ms": \(f(p.percentile(75)))
      }
    """
}

func perTickVacBlock(_ p: PerTickAmps?) -> String {
    guard let p = p, p.count > 0 else { return "null" }
    let pulses = "[" + p.pulsesMs.map { String(format: "%.4f", $0) }.joined(separator: ",") + "]"
    let amps = "[" + p.ampsDeg.map { String(format: "%.2f", $0) }.joined(separator: ",") + "]"
    func f(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "null" }
    return """
    {
        "pulses_ms": \(pulses),
        "amps_deg": \(amps),
        "n": \(p.count),
        "median_pulse_ms": \(f(p.medianPulseMs)),
        "median_amp_deg": \(f(p.medianAmpDeg)),
        "p25_amp_deg": \(f(p.p25AmpDeg)),
        "p75_amp_deg": \(f(p.p75AmpDeg)),
        "mean_amp_deg": \(f(p.meanAmpDeg)),
        "std_amp_deg": \(f(p.stdAmpDeg)),
        "median_stderr_deg": \(f(p.medianStdErrDeg))
      }
    """
}

func writeMeasurementsJson(
    anatomy: AnatomyResult, tick: ClassMeasurements?, tock: ClassMeasurements?,
    liftAngleDeg: Double, vacaboja: VacabojaAmplitude
) {
    func kv(_ key: String, _ val: Double?) -> String {
        if let v = val, v.isFinite { return "\"\(key)\": \(String(format: "%.4f", v))" }
        return "\"\(key)\": null"
    }
    func numArr(_ xs: [Double]) -> String {
        "[" + xs.map { String(format: "%.4f", $0) }.joined(separator: ",") + "]"
    }
    func classBlock(_ m: ClassMeasurements?) -> String {
        guard let m = m else { return "null" }
        let parts = [
            "\"phase_peaks_ms\": \(numArr(m.phasePeaksMs))",
            "\"phase_amps_rel\": \(numArr(m.phaseAmpsRel.map { Double($0) }))",
            kv("phase_amp_deg", m.phaseAmp),
            kv("mid_lead_ms", m.midLeadMs),
            kv("mid_trail_ms", m.midTrailMs),
            kv("mid_amp_deg", m.midAmp),
            kv("pulse_lead_ms", m.pulseLeadMs),
            kv("pulse_trail_ms", m.pulseTrailMs),
            kv("pulse_amp_deg", m.pulseAmp),
            kv("onset_lead_ms", m.onsetLeadMs),
            kv("onset_trail_ms", m.onsetTrailMs),
            kv("onset_amp_deg", m.onsetAmp),
        ]
        return "{\n    " + parts.joined(separator: ",\n    ") + "\n  }"
    }
    let bph = anatomy.snappedBph
    let beatPeriodMs = anatomy.beatPeriod * 1000
    let json = """
    {
      "file": "\(anatomy.filename)",
      "bph": \(bph),
      "beat_period_ms": \(String(format: "%.3f", beatPeriodMs)),
      "quality": \(anatomy.quality),
      "lift_angle_deg": \(liftAngleDeg),
      "half_window_ms": \(halfWindowMs),
      "sample_rate": \(Int(anatomy.sampleRate)),
      "tick": \(classBlock(tick)),
      "tock": \(classBlock(tock)),
      "tick_per_tick": \(perTickBlock(anatomy.tickPerTick)),
      "tock_per_tick": \(perTickBlock(anatomy.tockPerTick)),
      "tick_per_tick_3ms": \(perTickBlock(anatomy.tickPerTick3)),
      "tock_per_tick_3ms": \(perTickBlock(anatomy.tockPerTick3)),
      "tick_per_tick_vacaboja": \(perTickVacBlock(anatomy.tickPerTickVac)),
      "tock_per_tick_vacaboja": \(perTickVacBlock(anatomy.tockPerTickVac)),
      "vacaboja": {
        \(kv("tick_pulse_ms", vacaboja.tickPulseMs)),
        \(kv("tock_pulse_ms", vacaboja.tockPulseMs)),
        \(kv("tick_amp_deg", vacaboja.tickAmpDeg)),
        \(kv("tock_amp_deg", vacaboja.tockAmpDeg)),
        \(kv("combined_amp_deg", vacaboja.combinedAmpDeg)),
        \(kv("threshold_pct_glob_max", vacaboja.thresholdPctOfGlobMax))
      }
    }
    """
    let jsonName = (anatomy.filename as NSString).deletingPathExtension + ".anatomy.json"
    try? json.write(to: URL(fileURLWithPath: jsonName), atomically: true, encoding: .utf8)
    FileHandle.standardError.write("wrote \(jsonName)\n".data(using: .utf8)!)
}

/// Per-tick traces JSON: serializes the picker-candidate comparison data so
/// `plot_onsets.py` can overlay individual ticks with their argmax/centroid/
/// onset markers and show histograms of inter-tick spacing for each method.
func writeOnsetsJson(_ a: AnatomyResult) {
    func optMs(_ v: Double?) -> String {
        if let v = v, v.isFinite { return String(format: "%.4f", v) }
        return "null"
    }
    func traceBlock(_ t: PerTickTrace) -> String {
        let env = "[" + t.envSamples.map { String(format: "%.6f", $0) }.joined(separator: ",") + "]"
        let flux = "[" + t.fluxSamples.map { String(format: "%.6f", $0) }.joined(separator: ",") + "]"
        return """
        {
          "beat_index": \(t.beatIndex),
          "is_even": \(t.isEven),
          "center_sample_abs": \(t.centerSampleAbs),
          "env_half_ms": \(String(format: "%.3f", t.envHalfMs)),
          "argmax_ms": \(String(format: "%.4f", t.argmaxMs)),
          "centroid_ms": \(optMs(t.centroidMs)),
          "onset_20pct_ms": \(optMs(t.onsetMs20pct)),
          "onset_5sigma_ms": \(optMs(t.onsetMs5sigma)),
          "flux_peak_ms": \(optMs(t.fluxPeakMs)),
          "flux_onset_ms": \(optMs(t.fluxOnsetMs)),
          "flux_first_ms": \(optMs(t.fluxFirstMs)),
          "matched_ms": \(optMs(t.matchedMs)),
          "env": \(env),
          "flux": \(flux)
        }
        """
    }
    let tickArr = a.tickTraces.map { traceBlock($0) }.joined(separator: ",\n  ")
    let tockArr = a.tockTraces.map { traceBlock($0) }.joined(separator: ",\n  ")
    let json = """
    {
      "file": "\(a.filename)",
      "bph": \(a.snappedBph),
      "beat_period_ms": \(String(format: "%.4f", a.beatPeriod * 1000)),
      "sample_rate": \(Int(a.sampleRate)),
      "ticks": [
      \(tickArr)
      ],
      "tocks": [
      \(tockArr)
      ]
    }
    """
    let name = (a.filename as NSString).deletingPathExtension + ".onsets.json"
    try? json.write(to: URL(fileURLWithPath: name), atomically: true, encoding: .utf8)
    FileHandle.standardError.write("wrote \(name)\n".data(using: .utf8)!)
}

// MARK: - Main

print("file,bph,q%,tick_n,tick_med_snr,tock_n,tock_med_snr,tick_peak_ms,tock_peak_ms")

for path in files {
    guard let a = processFile(path) else { continue }

    // Find envelope peak times relative to window center.
    func peakMs(_ avg: Averaged?, sampleRate: Double) -> String {
        guard let avg = avg else { return "" }
        let n = avg.envelope.count
        var maxIdx = 0; var maxVal: Float = 0
        for i in 0..<n { if avg.envelope[i] > maxVal { maxVal = avg.envelope[i]; maxIdx = i } }
        let half = n / 2
        let ms = Double(maxIdx - half) / sampleRate * 1000.0
        return String(format: "%.3f", ms)
    }

    let tickN = a.tickAvg?.count ?? 0
    let tockN = a.tockAvg?.count ?? 0
    let tickSnr = medianSnr(a.tickAvg?.keptSnr ?? [])
    let tockSnr = medianSnr(a.tockAvg?.keptSnr ?? [])
    let tickPeak = peakMs(a.tickAvg, sampleRate: a.sampleRate)
    let tockPeak = peakMs(a.tockAvg, sampleRate: a.sampleRate)

    print(String(format: "%@,%d,%d,%d,%.2f,%d,%.2f,%@,%@",
                 a.filename, a.snappedBph, a.quality, tickN, tickSnr, tockN, tockSnr, tickPeak, tockPeak))
    writeCsv(a)

    // Terminal visualization
    print("")
    print("  \(a.filename)  \(a.snappedBph) bph  q=\(a.quality)%  period=\(String(format: "%.1f", a.beatPeriod * 1000))ms  lift=\(String(format: "%.0f", liftAngleDeg))°")
    var tickPhase: Double? = nil; var tockPhase: Double? = nil
    var tickMid: Double? = nil;   var tockMid: Double? = nil
    var tickPulse: Double? = nil; var tockPulse: Double? = nil
    var tickOnset: Double? = nil; var tockOnset: Double? = nil
    var tickMeas: ClassMeasurements? = nil
    var tockMeas: ClassMeasurements? = nil
    if let t = a.tickAvg {
        let out = printAscii(
            title: "  TICK (even beats) — n=\(t.count), median SNR=\(String(format: "%.2f", medianSnr(t.keptSnr)))",
            waveform: t.waveform, fineEnv: t.envelope, midEnv: t.midEnvelope, pulseEnv: t.pulseEnvelope,
            halfWindowMs: halfWindowMs, sampleRate: a.sampleRate,
            beatPeriodSec: a.beatPeriod, liftAngleDeg: liftAngleDeg
        )
        tickPhase = out.phaseAmp; tickMid = out.midAmp; tickPulse = out.pulseAmp; tickOnset = out.onsetAmp
        tickMeas = out.measurements
    }
    if let t = a.tockAvg {
        let out = printAscii(
            title: "  TOCK (odd beats)  — n=\(t.count), median SNR=\(String(format: "%.2f", medianSnr(t.keptSnr)))",
            waveform: t.waveform, fineEnv: t.envelope, midEnv: t.midEnvelope, pulseEnv: t.pulseEnvelope,
            halfWindowMs: halfWindowMs, sampleRate: a.sampleRate,
            beatPeriodSec: a.beatPeriod, liftAngleDeg: liftAngleDeg
        )
        tockPhase = out.phaseAmp; tockMid = out.midAmp; tockPulse = out.pulseAmp; tockOnset = out.onsetAmp
        tockMeas = out.measurements
    }
    // Reference implementation: vacaboja/tg amplitude (1ms peak-hold + box-mean,
    // threshold sweep from noise floor to 20% of global max, accept first
    // threshold with both amps in [135°, 360°] and |tick−tock|<60°).
    // Source: https://github.com/vacaboja/tg, src/algo.c lines 611–812.
    let vac = vacabojaAmplitude(
        tickWf: a.tickAvg?.waveform, tockWf: a.tockAvg?.waveform,
        sampleRate: a.sampleRate, beatPeriodSec: a.beatPeriod,
        halfWindowMs: halfWindowMs, liftAngleDeg: liftAngleDeg
    )
    writeMeasurementsJson(anatomy: a, tick: tickMeas, tock: tockMeas,
                          liftAngleDeg: liftAngleDeg, vacaboja: vac)
    writeOnsetsJson(a)
    func combine(_ a: Double?, _ b: Double?) -> (Double?, String) {
        if let a = a, let b = b { return ((a + b) / 2, String(format: "  (tick-tock=%+.0f°)", a - b)) }
        return (a ?? b, "")
    }
    let (phaseCombined, phaseAsym) = combine(tickPhase, tockPhase)
    let (midCombined,   midAsym)   = combine(tickMid,   tockMid)
    let (pulseCombined, pulseAsym) = combine(tickPulse, tockPulse)
    let (onsetCombined, onsetAsym) = combine(tickOnset, tockOnset)
    print(String(format: "  AMPLITUDE (phase-span):   %@%@", fmtAmp(phaseCombined), phaseAsym))
    print(String(format: "  AMPLITUDE (1ms env):      %@%@", fmtAmp(midCombined),   midAsym))
    print(String(format: "  AMPLITUDE (3ms env):      %@%@", fmtAmp(pulseCombined), pulseAsym))
    print(String(format: "  AMPLITUDE (onset-SNR):    %@%@", fmtAmp(onsetCombined), onsetAsym))

    // Per-tick (no coherent averaging) — each tick measured independently,
    // then aggregated. This is the test: does coherent averaging narrow
    // pulses, or do they just come out short on each tick too?
    func perTickLine(_ label: String, _ p: PerTickWidths?) {
        guard let p = p, p.count > 0 else {
            print("  \(label)  n=0  —")
            return
        }
        let med = p.median ?? 0
        let mean = p.mean ?? 0
        let std = p.std ?? 0
        let p25 = p.percentile(25) ?? 0
        let p75 = p.percentile(75) ?? 0
        let ampMed = AmplitudeEstimator.amplitude(
            pulseMs: med, beatPeriodSeconds: a.beatPeriod, liftAngleDegrees: liftAngleDeg
        )
        let ampMean = AmplitudeEstimator.amplitude(
            pulseMs: mean, beatPeriodSeconds: a.beatPeriod, liftAngleDegrees: liftAngleDeg
        )
        print(String(format: "  %@  n=%d  median=%.2fms (p25=%.2f, p75=%.2f)  mean=%.2f±%.2fms   amp(med)=%@  amp(mean)=%@",
                     label, p.count, med, p25, p75, mean, std, fmtAmp(ampMed), fmtAmp(ampMean)))
    }
    print("  PER-TICK (1ms env, no coherent avg):")
    perTickLine("    tick:", a.tickPerTick)
    perTickLine("    tock:", a.tockPerTick)
    print("  PER-TICK (3ms env, matches AmplitudeEstimator smoothing):")
    perTickLine("    tick:", a.tickPerTick3)
    perTickLine("    tock:", a.tockPerTick3)

    func combinedMed(_ t: PerTickWidths?, _ k: PerTickWidths?) -> Double? {
        switch (t?.median, k?.median) {
        case let (a?, b?): return (a + b) / 2
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
    let med1 = combinedMed(a.tickPerTick, a.tockPerTick)
    let med3 = combinedMed(a.tickPerTick3, a.tockPerTick3)
    let amp1 = med1.flatMap { AmplitudeEstimator.amplitude(
        pulseMs: $0, beatPeriodSeconds: a.beatPeriod, liftAngleDegrees: liftAngleDeg) }
    let amp3 = med3.flatMap { AmplitudeEstimator.amplitude(
        pulseMs: $0, beatPeriodSeconds: a.beatPeriod, liftAngleDegrees: liftAngleDeg) }
    print(String(format: "  AMPLITUDE (per-tick 1ms med): %@", fmtAmp(amp1)))
    print(String(format: "  AMPLITUDE (per-tick 3ms med): %@", fmtAmp(amp3)))

    // Per-tick vacaboja (primary candidate for production use). Tick and tock
    // are kept separate so beat-error asymmetries don't contaminate the
    // combined number.
    print("  PER-TICK (vacaboja 1ms peak-hold, threshold sweep):")
    func perTickVacLine(_ label: String, _ p: PerTickAmps?, nCandidates: Int) {
        guard let p = p, p.count > 0 else {
            print("  \(label)  0/\(nCandidates)  —")
            return
        }
        let med = p.medianAmpDeg ?? 0
        let p25 = p.p25AmpDeg ?? 0
        let p75 = p.p75AmpDeg ?? 0
        let se = p.medianStdErrDeg ?? 0
        let pm = p.medianPulseMs ?? 0
        print(String(format: "  %@  %d/%d  median=%.0f° (p25=%.0f, p75=%.0f)  ±%.0f° (1σ med)  pulse_med=%.2fms",
                     label, p.count, nCandidates, med, p25, p75, se, pm))
    }
    // Use per-tick-1ms counts as a rough "ticks we started with" denominator.
    let nTick = a.tickPerTick?.count ?? 0
    let nTock = a.tockPerTick?.count ?? 0
    perTickVacLine("    tick:", a.tickPerTickVac, nCandidates: nTick)
    perTickVacLine("    tock:", a.tockPerTickVac, nCandidates: nTock)

    // Combined tick+tock for display: average of the two class medians if both
    // converged, else whichever is available.
    func combineMedians(_ tk: PerTickAmps?, _ tc: PerTickAmps?) -> Double? {
        switch (tk?.medianAmpDeg, tc?.medianAmpDeg) {
        case let (a?, b?): return (a + b) / 2
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
    let vacTickMed = a.tickPerTickVac?.medianAmpDeg
    let vacTockMed = a.tockPerTickVac?.medianAmpDeg
    let vacCombined = combineMedians(a.tickPerTickVac, a.tockPerTickVac)
    let asymStr = (vacTickMed != nil && vacTockMed != nil)
        ? String(format: "  (tick-tock=%+.0f°)", vacTickMed! - vacTockMed!) : ""
    print(String(format: "  AMPLITUDE (per-tick vacaboja combined): %@%@",
                 fmtAmp(vacCombined), asymStr))

    let vacPulseStr: String = {
        let t = vac.tickPulseMs.map { String(format: "%.2fms", $0) } ?? "-"
        let k = vac.tockPulseMs.map { String(format: "%.2fms", $0) } ?? "-"
        let th = vac.thresholdPctOfGlobMax.map { String(format: "%.1f%% glob_max", $0) } ?? "-"
        return "(tick=\(t), tock=\(k), threshold=\(th))"
    }()
    print(String(format: "  AMPLITUDE (vacaboja 1ms peak-hold + sweep): %@  %@",
                 fmtAmp(vac.combinedAmpDeg), vacPulseStr))

    // Cross-check against the production AmplitudeEstimator running on the raw
    // buffer. This is what the app Result screen would show today.
    if let buffer = try? WAVReader.read(url: URL(fileURLWithPath: path)) {
        let est = AmplitudeEstimator()
        let pipeline = MeasurementPipeline()
        let result = pipeline.measure(buffer)
        let pw = est.measurePulseWidths(
            input: buffer, rate: result.snappedRate,
            rateErrorSecondsPerDay: result.rateErrorSecondsPerDay,
            tickTimings: result.tickTimings
        )
        let prodAmp = AmplitudeEstimator.combinedAmplitude(
            pulseWidths: pw, beatRate: result.snappedRate,
            rateErrorSecondsPerDay: result.rateErrorSecondsPerDay,
            liftAngleDegrees: liftAngleDeg
        )
        let tickMsStr = pw.tickPulseMs.map { String(format: "%.2fms", $0) } ?? "-"
        let tockMsStr = pw.tockPulseMs.map { String(format: "%.2fms", $0) } ?? "-"
        print(String(format: "  AMPLITUDE (AmplitudeEstimator fold+3ms): %@  (tick=%@, tock=%@, folds=%d)",
                     fmtAmp(prodAmp), tickMsStr, tockMsStr, pw.foldCount))
    }
    print("")
}
