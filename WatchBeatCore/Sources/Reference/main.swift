// Reference picker — a standalone, deliberately simple tool for measuring
// rate and beat-position spread on clean recordings (e.g., Omega 485). Does
// NOT use MeasurementPipeline; everything lives in this file.
//
// Pipeline:
//   1. Load WAV.
//   2. Highpass at 5 kHz (same as production) to suppress room rumble / hum.
//   3. Square the signal.
//   4. Lightly smooth (1 ms boxcar at 48 kHz, configurable) and decimate to
//      1 kHz envelope for FFT.
//   5. Subtract DC, Hann-window, complex FFT.
//   6. Find peak bin in [4 Hz, 11 Hz] (mechanical-watch range), parabolic-
//      interpolate for sub-bin frequency.
//   7. Read phase at the peak bin → first-beat time t₀.
//   8. Generate window centers at fHz cadence covering the recording.
//   9. For each window, take ±half-period of the *full-rate smoothed
//      squared* signal, find argmax. That is the beat position.
//  10. Linear regression on (i, beatPos[i]). Slope → period → s/day error.
//      Residuals → beat-position spread.
//  11. Write a residuals JSON for plotting.
//
// No tick/tock distinction. No matched filter. No rescue. No centroid. The
// only smoothing is the configurable boxcar in step 4 (envelope FFT input)
// and step 9 (per-window argmax). Everything else is a peak-find.

import Foundation
import Accelerate
import WatchBeatCore

// MARK: - Args

guard CommandLine.arguments.count > 1 else {
    print("Usage: Reference <file.wav> [smoothMs]")
    print("  smoothMs: optional boxcar half-width in ms applied to squared")
    print("            signal before per-window argmax. Default 1.0 ms.")
    print("            Use 0 for no smoothing.")
    exit(1)
}

let path = CommandLine.arguments[1]
let smoothMs: Double = CommandLine.arguments.count > 2
    ? (Double(CommandLine.arguments[2]) ?? 1.0)
    : 1.0

let url = URL(fileURLWithPath: path)
let buffer: AudioBuffer
do {
    buffer = try WAVReader.read(url: url)
} catch {
    print("Error reading \(path): \(error)")
    exit(1)
}

let sampleRate = buffer.sampleRate
let fileName = url.lastPathComponent
print("=== \(fileName) ===")
print("  sampleRate: \(sampleRate) Hz, duration: \(String(format: "%.3f", Double(buffer.samples.count) / sampleRate)) s")
print("  smoothing:  \(smoothMs) ms boxcar half-width")

// MARK: - 1. Highpass + square

let conditioner = SignalConditioner()
let filtered = conditioner.highpassFilter(buffer.samples, sampleRate: sampleRate, cutoff: 5000.0)

let n = filtered.count
var squared = [Float](repeating: 0, count: n)
vDSP_vsq(filtered, 1, &squared, 1, vDSP_Length(n))

// Optional light smoothing of squared signal (used for per-window argmax).
let smoothSamples = max(1, Int(smoothMs * 0.001 * sampleRate)) | 1  // odd
let smoothed: [Float]
if smoothSamples > 1 {
    var s = [Float](repeating: 0, count: n)
    let half = smoothSamples / 2
    var sum: Float = 0
    for i in 0..<min(smoothSamples, n) { sum += squared[i] }
    for i in 0..<n {
        let lo = max(0, i - half)
        let hi = min(n - 1, i + half)
        // Recompute window sum directly — clean and clear, n is small enough.
        var ws: Float = 0
        vDSP_sve(squared.withUnsafeBufferPointer { $0.baseAddress! + lo }, 1,
                 &ws, vDSP_Length(hi - lo + 1))
        s[i] = ws / Float(hi - lo + 1)
    }
    smoothed = s
} else {
    smoothed = squared
}

// MARK: - 2. Decimate to 1 kHz envelope for FFT

let decimFactor = max(1, Int(sampleRate / 1000.0))
let envRate = sampleRate / Double(decimFactor)
let envN = n / decimFactor
var env = [Float](repeating: 0, count: envN)
for i in 0..<envN {
    var ws: Float = 0
    vDSP_sve(squared.withUnsafeBufferPointer { $0.baseAddress! + i * decimFactor }, 1,
             &ws, vDSP_Length(decimFactor))
    env[i] = ws / Float(decimFactor)
}

// Subtract DC.
var meanEnv: Float = 0
vDSP_meanv(env, 1, &meanEnv, vDSP_Length(envN))
var negMean = -meanEnv
vDSP_vsadd(env, 1, &negMean, &env, 1, vDSP_Length(envN))

// Apply Hann window before FFT.
var hann = [Float](repeating: 0, count: envN)
vDSP_hann_window(&hann, vDSP_Length(envN), Int32(vDSP_HANN_NORM))
vDSP_vmul(env, 1, hann, 1, &env, 1, vDSP_Length(envN))

// MARK: - 3. Complex FFT

func nextPow2(_ x: Int) -> Int {
    var v = 1
    while v < x { v <<= 1 }
    return v
}

let fftLength = nextPow2(envN)
var padded = [Float](repeating: 0, count: fftLength)
padded.replaceSubrange(0..<envN, with: env)

let log2n = vDSP_Length(log2(Double(fftLength)))
guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
    print("FFT setup failed")
    exit(1)
}
defer { vDSP_destroy_fftsetup(fftSetup) }

let halfN = fftLength / 2
var realPart = [Float](repeating: 0, count: halfN)
var imagPart = [Float](repeating: 0, count: halfN)
padded.withUnsafeBufferPointer { buf in
    for i in 0..<halfN {
        realPart[i] = buf[2 * i]
        imagPart[i] = buf[2 * i + 1]
    }
}
realPart.withUnsafeMutableBufferPointer { rb in
    imagPart.withUnsafeMutableBufferPointer { ib in
        var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }
}

let freqRes = envRate / Double(fftLength)

// MARK: - 4. Find peak in [4, 11] Hz, parabolic-interpolate frequency

let lowBin = max(1, Int(4.0 / freqRes))
let highBin = min(halfN - 2, Int(11.0 / freqRes))
var peakBin = lowBin
var peakMag2: Float = -.infinity
for b in lowBin...highBin {
    let m2 = realPart[b] * realPart[b] + imagPart[b] * imagPart[b]
    if m2 > peakMag2 { peakMag2 = m2; peakBin = b }
}

var fHz = Double(peakBin) * freqRes
if peakBin > 1 && peakBin < halfN - 1 {
    let mLeft = sqrt(Double(realPart[peakBin - 1] * realPart[peakBin - 1] + imagPart[peakBin - 1] * imagPart[peakBin - 1]))
    let mPeak = sqrt(Double(peakMag2))
    let mRight = sqrt(Double(realPart[peakBin + 1] * realPart[peakBin + 1] + imagPart[peakBin + 1] * imagPart[peakBin + 1]))
    let denom = mLeft - 2 * mPeak + mRight
    if abs(denom) > 1e-12 {
        var delta = 0.5 * (mLeft - mRight) / denom
        if delta > 0.5 { delta = 0.5 }
        if delta < -0.5 { delta = -0.5 }
        fHz = (Double(peakBin) + delta) * freqRes
    }
}

// Phase at peak bin.
let phi = atan2(Double(imagPart[peakBin]), Double(realPart[peakBin]))

// Asymmetry test: an asymmetric beat (tick/tock with different intervals)
// produces sub-harmonic energy at fHz/2 (the "tick rate" — every other beat).
// Multi-sub-event tick structure within each beat produces harmonic energy
// at 2·fHz, 3·fHz, ... (the shape of one beat). Comparing magnitudes at
// these distinguishes the two:
//   strong f and f/2 ≈ comparable → real tick/tock asymmetry
//   strong f, weaker 2f, 3f, ... → multi-sub-event tick (no asymmetry)
func magAt(hz: Double) -> Double {
    let bin = Int(round(hz / freqRes))
    guard bin > 0 && bin < halfN else { return 0 }
    return sqrt(Double(realPart[bin] * realPart[bin] + imagPart[bin] * imagPart[bin]))
}
let magF = magAt(hz: fHz)
let magHalf = magAt(hz: fHz / 2.0)
let mag2 = magAt(hz: 2.0 * fHz)
let mag3 = magAt(hz: 3.0 * fHz)
let mag4 = magAt(hz: 4.0 * fHz)

let periodSec = 1.0 / fHz
let periodMs = periodSec * 1000.0
let nominalRates: [(name: String, hz: Double)] = [
    ("18000", 5.0), ("19800", 5.5), ("21600", 6.0),
    ("25200", 7.0), ("28800", 8.0), ("36000", 10.0),
]
let nearestNominal = nominalRates.min { abs($0.hz - fHz) < abs($1.hz - fHz) }!
let rateErrPerDay = (fHz / nearestNominal.hz - 1.0) * 86400.0

print("  FFT peak:   \(String(format: "%.4f", fHz)) Hz  (period \(String(format: "%.4f", periodMs)) ms)")
print("  Nearest:    \(nearestNominal.name) bph (\(String(format: "%.4f", nearestNominal.hz)) Hz)")
print("  FFT-rate:   \(String(format: "%+.1f", rateErrPerDay)) s/day vs nominal")
print("  Phase:      \(String(format: "%.4f", phi)) rad")
print("  Spectrum:   |f|=\(String(format: "%.4f", magF))   |f/2|=\(String(format: "%.4f", magHalf))   |2f|=\(String(format: "%.4f", mag2))   |3f|=\(String(format: "%.4f", mag3))   |4f|=\(String(format: "%.4f", mag4))")
print("              ratios: f/2÷f=\(String(format: "%.3f", magHalf/magF))   2f÷f=\(String(format: "%.3f", mag2/magF))   3f÷f=\(String(format: "%.3f", mag3/magF))")

// MARK: - 5. Generate window centers from FFT phase

// Continuous-time peak-position model: env(t) ≈ A·cos(2π·fHz·t + phi)
// Peaks at t such that 2π·fHz·t + phi = 2π·k → t_k = (k − phi/(2π)) / fHz.
// Pick k₀ as the smallest k giving t_k ≥ halfPeriod, then enumerate all k
// with t_k + halfPeriod < duration.
let phaseShift = phi / (2.0 * .pi)
let halfPeriodSamples = Int(periodSec * sampleRate / 2.0)
let durationSec = Double(n) / sampleRate

var windowCenters: [Double] = []  // beat positions in seconds
var k = Int(ceil(phaseShift + (Double(halfPeriodSamples) / sampleRate) * fHz))
while true {
    let t = (Double(k) - phaseShift) / fHz
    if t + Double(halfPeriodSamples) / sampleRate >= durationSec { break }
    if t - Double(halfPeriodSamples) / sampleRate >= 0 { windowCenters.append(t) }
    k += 1
}

print("  Beats:      \(windowCenters.count) windows from FFT phase")

// MARK: - 6. Per-window argmax on smoothed squared

var beatPositions: [Double] = []  // absolute time of argmax (seconds)
for tc in windowCenters {
    let centerSample = Int(round(tc * sampleRate))
    let lo = max(0, centerSample - halfPeriodSamples)
    let hi = min(n - 1, centerSample + halfPeriodSamples)
    var bestIdx = lo
    var bestVal: Float = -.infinity
    for i in lo...hi {
        if smoothed[i] > bestVal { bestVal = smoothed[i]; bestIdx = i }
    }
    beatPositions.append(Double(bestIdx) / sampleRate)
}

// MARK: - 7. Linear regression: t_i = slope · i + intercept

let m = beatPositions.count
guard m >= 2 else {
    print("  Not enough beats")
    exit(1)
}

var sumI: Double = 0
var sumT: Double = 0
var sumII: Double = 0
var sumIT: Double = 0
for i in 0..<m {
    let di = Double(i)
    sumI += di
    sumT += beatPositions[i]
    sumII += di * di
    sumIT += di * beatPositions[i]
}
let dm = Double(m)
let denom = dm * sumII - sumI * sumI
let slope = (dm * sumIT - sumI * sumT) / denom
let intercept = (sumT - slope * sumI) / dm

let measuredPeriodMs = slope * 1000.0
let regRateErr = (1.0 / slope / nearestNominal.hz - 1.0) * 86400.0

// Residuals.
var residualsMs = [Double](repeating: 0, count: m)
for i in 0..<m {
    residualsMs[i] = (beatPositions[i] - (slope * Double(i) + intercept)) * 1000.0
}

let meanRes = residualsMs.reduce(0, +) / Double(m)
let variance = residualsMs.map { ($0 - meanRes) * ($0 - meanRes) }.reduce(0, +) / Double(m)
let stdRes = sqrt(variance)
let maxAbsRes = residualsMs.map { abs($0) }.max() ?? 0

// Even/odd split for diagnostic only — no class assumption baked into picker.
var evenRes: [Double] = []
var oddRes: [Double] = []
for i in 0..<m {
    if i % 2 == 0 { evenRes.append(residualsMs[i]) } else { oddRes.append(residualsMs[i]) }
}
let evenMean = evenRes.reduce(0, +) / Double(max(1, evenRes.count))
let oddMean = oddRes.reduce(0, +) / Double(max(1, oddRes.count))
let evenStd = sqrt(evenRes.map { ($0 - evenMean) * ($0 - evenMean) }.reduce(0, +) / Double(max(1, evenRes.count)))
let oddStd = sqrt(oddRes.map { ($0 - oddMean) * ($0 - oddMean) }.reduce(0, +) / Double(max(1, oddRes.count)))
let beAsymmetry = abs(evenMean - oddMean)

print("")
print("  Reg-period: \(String(format: "%.4f", measuredPeriodMs)) ms")
print("  Reg-rate:   \(String(format: "%+.1f", regRateErr)) s/day vs \(nearestNominal.name)")
print("  Residuals:  mean=\(String(format: "%.3f", meanRes)) ms  σ=\(String(format: "%.3f", stdRes)) ms  max|·|=\(String(format: "%.3f", maxAbsRes)) ms")
print("  Even (n=\(evenRes.count)): μ=\(String(format: "%+.3f", evenMean)) σ=\(String(format: "%.3f", evenStd)) ms")
print("  Odd  (n=\(oddRes.count)): μ=\(String(format: "%+.3f", oddMean)) σ=\(String(format: "%.3f", oddStd)) ms")
print("  Even/odd asymmetry: \(String(format: "%.3f", beAsymmetry)) ms  (= 'beat error' if real)")

// MARK: - 7b. Per-class average envelope SHAPE around argmax (Test 2)
//
// Align each beat's envelope on its own argmax (subtract that beat's peak
// position), peak-normalize the window, then average per class. If the two
// class shapes are identical, the picker is finding the same physical
// sub-event in every beat — apparent asymmetry is real beat error. If the
// shapes differ (e.g., one has a taller leading peak, other has a taller
// trailing peak), the picker is locking onto different sub-events for the
// two classes — apparent asymmetry is a windowing artifact.

let shapeHalfMs: Double = 25.0
let shapeHalfSamples = Int(shapeHalfMs * 0.001 * sampleRate)
let shapeWidth = 2 * shapeHalfSamples + 1

var evenShape = [Double](repeating: 0, count: shapeWidth)
var oddShape = [Double](repeating: 0, count: shapeWidth)
var evenShapeCount = 0
var oddShapeCount = 0

for i in 0..<m {
    let argmaxSample = Int(round(beatPositions[i] * sampleRate))
    let lo = argmaxSample - shapeHalfSamples
    let hi = argmaxSample + shapeHalfSamples
    guard lo >= 0 && hi < n else { continue }

    var localPeak: Float = 0
    for j in lo...hi {
        if smoothed[j] > localPeak { localPeak = smoothed[j] }
    }
    guard localPeak > 0 else { continue }

    if i % 2 == 0 {
        for k in 0..<shapeWidth {
            evenShape[k] += Double(smoothed[lo + k] / localPeak)
        }
        evenShapeCount += 1
    } else {
        for k in 0..<shapeWidth {
            oddShape[k] += Double(smoothed[lo + k] / localPeak)
        }
        oddShapeCount += 1
    }
}

if evenShapeCount > 0 {
    for k in 0..<shapeWidth { evenShape[k] /= Double(evenShapeCount) }
}
if oddShapeCount > 0 {
    for k in 0..<shapeWidth { oddShape[k] /= Double(oddShapeCount) }
}

var rmsDiff: Double = 0
for k in 0..<shapeWidth {
    let d = evenShape[k] - oddShape[k]
    rmsDiff += d * d
}
rmsDiff = sqrt(rmsDiff / Double(shapeWidth))

var evenShapeArgmax = 0
var oddShapeArgmax = 0
var evMax = -Double.infinity
var odMax = -Double.infinity
for k in 0..<shapeWidth {
    if evenShape[k] > evMax { evMax = evenShape[k]; evenShapeArgmax = k - shapeHalfSamples }
    if oddShape[k] > odMax { odMax = oddShape[k]; oddShapeArgmax = k - shapeHalfSamples }
}
let evenShapeArgmaxMs = Double(evenShapeArgmax) / sampleRate * 1000.0
let oddShapeArgmaxMs = Double(oddShapeArgmax) / sampleRate * 1000.0

print("")
print("  --- Test 2: per-class shape (argmax-aligned, peak-normalized) ---")
print("  Even shape argmax offset: \(String(format: "%+.3f", evenShapeArgmaxMs)) ms (should be 0 by construction)")
print("  Odd  shape argmax offset: \(String(format: "%+.3f", oddShapeArgmaxMs)) ms (should be 0 by construction)")
print("  Class-shape RMS difference: \(String(format: "%.4f", rmsDiff)) (peak-normalized; 0 = identical, ≥0.05 = clearly different)")

// MARK: - 8. Write residuals JSON for plotting

struct ResidualsOutput: Encodable {
    let fileName: String
    let durationSec: Double
    let smoothMs: Double
    let fftFhz: Double
    let fftRateErrPerDay: Double
    let fftPhi: Double
    let regSlopeMs: Double
    let regRateErrPerDay: Double
    let nearestRateName: String
    let nearestRateHz: Double
    let beats: [Beat]
    let residualMean: Double
    let residualStd: Double
    let evenMean: Double
    let oddMean: Double
    let beAsymmetry: Double
    let shapeSampleRate: Double
    let shapeHalfMs: Double
    let evenShape: [Double]
    let oddShape: [Double]
    let evenShapeArgmaxMs: Double
    let oddShapeArgmaxMs: Double
    let shapeRmsDiff: Double
    struct Beat: Encodable {
        let index: Int
        let timeSec: Double
        let residualMs: Double
        let isEven: Bool
    }
}

let beats = (0..<m).map {
    ResidualsOutput.Beat(
        index: $0,
        timeSec: beatPositions[$0],
        residualMs: residualsMs[$0],
        isEven: $0 % 2 == 0
    )
}
let out = ResidualsOutput(
    fileName: fileName,
    durationSec: durationSec,
    smoothMs: smoothMs,
    fftFhz: fHz,
    fftRateErrPerDay: rateErrPerDay,
    fftPhi: phi,
    regSlopeMs: measuredPeriodMs,
    regRateErrPerDay: regRateErr,
    nearestRateName: nearestNominal.name,
    nearestRateHz: nearestNominal.hz,
    beats: beats,
    residualMean: meanRes,
    residualStd: stdRes,
    evenMean: evenMean,
    oddMean: oddMean,
    beAsymmetry: beAsymmetry,
    shapeSampleRate: sampleRate,
    shapeHalfMs: shapeHalfMs,
    evenShape: evenShape,
    oddShape: oddShape,
    evenShapeArgmaxMs: evenShapeArgmaxMs,
    oddShapeArgmaxMs: oddShapeArgmaxMs,
    shapeRmsDiff: rmsDiff
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let outURL = url.deletingPathExtension().appendingPathExtension("reference.json")
do {
    try encoder.encode(out).write(to: outURL)
    print("")
    print("  wrote \(outURL.path)")
} catch {
    print("Error writing JSON: \(error)")
}
