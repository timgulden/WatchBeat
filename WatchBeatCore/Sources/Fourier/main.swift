// Fourier — direct FFT-based measurement of rate, beat error, and tick
// sub-event structure. Standalone, no dependence on MeasurementPipeline's
// per-beat picker. Companion to the Reference tool: where Reference picks
// every beat individually and regresses, Fourier reads the answers directly
// from the harmonic structure of the 15-second envelope.
//
// Theory:
//   The envelope of a watch recording is a (mostly) periodic signal whose
//   Fourier series carries everything we want:
//     - Peak FFT bin near the watch's beat rate → exact rate (sub-bin
//       interpolated).
//     - The COMPLEX coefficient at the beat-rate bin (and harmonics) encodes
//       the average position of the dominant sub-event AND the shape of one
//       beat.
//     - The COMPLEX coefficient at half the beat rate (the sub-harmonic)
//       encodes the tick/tock asymmetry (= beat error). For a perfectly
//       symmetric watch (BE=0), this bin is zero. For BE ≠ 0, its magnitude
//       grows ∝ |sin(π·δ·f)| where δ is the asymmetry in seconds.
//     - Higher harmonics (2f, 3f, ...) encode the positions and amplitudes
//       of secondary sub-events of the tick (the "three parts" Tim observed
//       on Omega 485).
//
//   For a tick + tock model with each beat being a single δ-pulse:
//     env(t) = δ(t - t_T - 2mT_full) + δ(t - t_C - 2mT_full)  for all m
//     where T_full = 1/f_full = 2/f_beat, t_T = tick time, t_C = tock time.
//
//   Fourier coefficients (using f_half = f_beat/2 = 1/T_full):
//     c_n = (1/T_full) [exp(-2πi·n·f_half·t_T) + exp(-2πi·n·f_half·t_C)]
//
//   For n = 1 (sub-harmonic, at f_beat/2):
//     c_1 = (1/T_full) exp(-2πi·f_half·t_T) [1 - exp(-πi·δ·f_beat)]
//   where δ = (t_C - t_T) - 1/f_beat is the BE in seconds.
//
//   For n = 2 (fundamental at f_beat itself):
//     c_2 = (1/T_full) exp(-2πi·f_half·t_T) [1 + exp(-πi·δ·f_beat)] · 2
//   For δ=0 this is 2·exp(-2πi·f_half·t_T) — pure carrier.
//
//   So |c_1|/|c_2| ≈ |sin(π·δ·f_beat/2)| / |cos(π·δ·f_beat/2)| = |tan(π·δ·f_beat/2)|
//   for the simple δ-pulse model. Magnitude ratio ↔ BE directly.
//
//   The phase relationship between c_1 and c_2 also encodes the SIGN of δ
//   (which class is leading vs trailing).

import Foundation
import Accelerate
import WatchBeatCore

// MARK: - Args

guard CommandLine.arguments.count > 1 else {
    print("Usage: Fourier <file.wav>")
    exit(1)
}

let path = CommandLine.arguments[1]
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

// MARK: - 1. Highpass + square + decimate

let conditioner = SignalConditioner()
let filtered = conditioner.highpassFilter(buffer.samples, sampleRate: sampleRate, cutoff: 5000.0)
let n = filtered.count
var squared = [Float](repeating: 0, count: n)
vDSP_vsq(filtered, 1, &squared, 1, vDSP_Length(n))

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

// MARK: - 2. Two FFTs: WINDOWED for magnitude/peak find, UNWINDOWED for phase.
//
// Why two: a Hann window suppresses spectral leakage (good for finding
// peaks accurately) but distorts the absolute phase at non-bin-center
// frequencies. For phase recovery we need the unwindowed transform — phase
// at integer-bin samples of the periodic signal is preserved when no
// window is applied. The recording is exactly 15 seconds and the FFT length
// is the next power of 2 (16384 = 16.384 s); the small zero-padded tail is
// typically the dominant phase distortion source. We mitigate by truncating
// to the largest integer number of beat-periods that fits in the recording
// (so the periodic signal has whole-cycle support inside the FFT).

func nextPow2(_ x: Int) -> Int {
    var v = 1
    while v < x { v <<= 1 }
    return v
}

func fftMagPhase(_ x: [Float], length: Int) -> (real: [Float], imag: [Float]) {
    var padded = [Float](repeating: 0, count: length)
    padded.replaceSubrange(0..<min(x.count, length), with: x.prefix(length))
    let log2n = vDSP_Length(log2(Double(length)))
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    let halfN = length / 2
    var real = [Float](repeating: 0, count: halfN)
    var imag = [Float](repeating: 0, count: halfN)
    padded.withUnsafeBufferPointer { buf in
        for i in 0..<halfN {
            real[i] = buf[2 * i]
            imag[i] = buf[2 * i + 1]
        }
    }
    real.withUnsafeMutableBufferPointer { rb in
        imag.withUnsafeMutableBufferPointer { ib in
            var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        }
    }
    return (real, imag)
}

// First pass: windowed FFT to find the peak.
var hann = [Float](repeating: 0, count: envN)
vDSP_hann_window(&hann, vDSP_Length(envN), Int32(vDSP_HANN_NORM))
var windowed = [Float](repeating: 0, count: envN)
vDSP_vmul(env, 1, hann, 1, &windowed, 1, vDSP_Length(envN))

let fftLengthW = nextPow2(envN)
let (rW, iW) = fftMagPhase(windowed, length: fftLengthW)
let halfNW = fftLengthW / 2
let freqResW = envRate / Double(fftLengthW)

let lowBin = max(1, Int(4.0 / freqResW))
let highBin = min(halfNW - 2, Int(11.0 / freqResW))
var peakBin = lowBin
var peakMag2: Float = -.infinity
for b in lowBin...highBin {
    let m2 = rW[b] * rW[b] + iW[b] * iW[b]
    if m2 > peakMag2 { peakMag2 = m2; peakBin = b }
}
var fHz = Double(peakBin) * freqResW
if peakBin > 1 && peakBin < halfNW - 1 {
    let mL = sqrt(Double(rW[peakBin - 1] * rW[peakBin - 1] + iW[peakBin - 1] * iW[peakBin - 1]))
    let mP = sqrt(Double(peakMag2))
    let mR = sqrt(Double(rW[peakBin + 1] * rW[peakBin + 1] + iW[peakBin + 1] * iW[peakBin + 1]))
    let denom = mL - 2 * mP + mR
    if abs(denom) > 1e-12 {
        var delta = 0.5 * (mL - mR) / denom
        if delta > 0.5 { delta = 0.5 }
        if delta < -0.5 { delta = -0.5 }
        fHz = (Double(peakBin) + delta) * freqResW
    }
}

// MARK: - 3. Truncate envelope to integer beat-periods, FFT without windowing.
//
// Why integer periods: with whole-cycle support, the FFT bins at integer
// multiples of the fundamental (and at half-integer multiples for the sub-
// harmonic) correspond exactly to the Fourier-series coefficients of the
// periodic signal. Phase at each bin is then the real Fourier-series phase,
// directly interpretable.

let cyclesAvailable = Double(envN) / envRate * fHz
let intCycles = Int(floor(cyclesAvailable))
let halfCycles = intCycles - (intCycles % 2)  // even number → integer multiples of f/2 are bin-aligned
let truncSamples = Int(round(Double(halfCycles) / fHz * envRate))

let truncated = Array(env.prefix(truncSamples))
let truncN = truncated.count
let fftLengthU = nextPow2(truncN)

let (rU, iU) = fftMagPhase(truncated, length: fftLengthU)
let halfNU = fftLengthU / 2
let freqResU = envRate / Double(fftLengthU)

print("  Truncated to \(halfCycles) full beat cycles (\(String(format: "%.3f", Double(truncSamples) / envRate)) s) for clean Fourier-series interpretation.")
print("  fHz (windowed peak): \(String(format: "%.4f", fHz))")
print("  freq resolution (unwindowed FFT): \(String(format: "%.4f", freqResU)) Hz")

// Helper: complex coefficient at frequency hz.
func coeffAt(hz: Double) -> (real: Double, imag: Double, mag: Double, phase: Double) {
    let bin = Int(round(hz / freqResU))
    guard bin > 0 && bin < halfNU else { return (0, 0, 0, 0) }
    let r = Double(rU[bin])
    let i = Double(iU[bin])
    let m = sqrt(r * r + i * i)
    let p = atan2(i, r)
    return (r, i, m, p)
}

// MARK: - 4. Extract harmonics: f/2, f, 3f/2, 2f, 5f/2, 3f, 7f/2, 4f.

struct Harmonic {
    let label: String
    let hz: Double
    let mag: Double
    let phase: Double
    let real: Double
    let imag: Double
}

let multiples: [(String, Double)] = [
    ("f/2", 0.5),
    ("f", 1.0),
    ("3f/2", 1.5),
    ("2f", 2.0),
    ("5f/2", 2.5),
    ("3f", 3.0),
    ("7f/2", 3.5),
    ("4f", 4.0),
]

var harmonics: [Harmonic] = []
for (label, mult) in multiples {
    let c = coeffAt(hz: mult * fHz)
    harmonics.append(Harmonic(label: label, hz: mult * fHz, mag: c.mag, phase: c.phase, real: c.real, imag: c.imag))
}

let magF = harmonics.first { $0.label == "f" }!.mag
print("")
print("  Harmonic   freq(Hz)   |c|         |c|/|f|     phase(rad)")
for h in harmonics {
    let ratio = magF > 0 ? h.mag / magF : 0
    print("  \(h.label.padding(toLength: 8, withPad: " ", startingAt: 0))   \(String(format: "%.4f", h.hz).padding(toLength: 8, withPad: " ", startingAt: 0))   \(String(format: "%.6f", h.mag).padding(toLength: 10, withPad: " ", startingAt: 0))   \(String(format: "%.4f", ratio).padding(toLength: 8, withPad: " ", startingAt: 0))   \(String(format: "%+.4f", h.phase))")
}

// MARK: - 5. Direct measurements
//
// Rate: from fHz via FFT peak interpolation.
// BE: derive from |f/2| and the phase relationship between f/2 and f.
//
// For a 2-pulse model (tick + tock as δ-pulses with offsets t_T and t_C
// within the (tick+tock) cycle, where δ = (t_C − t_T) − 1/f_beat is BE):
//
//   c_2 (= bin at f_beat) = (2/T_full) · exp(−2πi·f_half·t_T) · cos(πδ·f_beat/2) · exp(−iπδ·f_beat/2)
//   c_1 (= bin at f_half) = (2/T_full) · exp(−2πi·f_half·t_T) · sin(πδ·f_beat/2) · exp(−iπδ·f_beat/2 − iπ/2)
//
// (working it out: 1 + exp(−πiδf) = 2·cos(πδf/2)·exp(−iπδf/2)
//                  1 − exp(−πiδf) = 2·sin(πδf/2)·exp(−iπδf/2 + iπ/2))
//
// So  c_1 / c_2 = (sin/cos)·exp(iπ/2) = tan(πδ·f_beat/2) · i  (purely imaginary)
//
// → δ = (2/(π·f_beat)) · atan(|c_1/c_2|),  sign from imag(c_1/c_2)
//
// This is the simplest model (single δ-pulse per beat). Multi-sub-event
// ticks complicate it because each sub-event contributes its own term, but
// the leading-order BE estimate from |c_1|/|c_2| is still meaningful.

let cF = harmonics.first { $0.label == "f" }!
let cHalf = harmonics.first { $0.label == "f/2" }!
let cF_complex = (real: cF.real, imag: cF.imag)
let cHalf_complex = (real: cHalf.real, imag: cHalf.imag)

// Compute c_1 / c_2 in complex.
let denom = cF_complex.real * cF_complex.real + cF_complex.imag * cF_complex.imag
let ratioReal = (cHalf_complex.real * cF_complex.real + cHalf_complex.imag * cF_complex.imag) / denom
let ratioImag = (cHalf_complex.imag * cF_complex.real - cHalf_complex.real * cF_complex.imag) / denom
let ratioMag = sqrt(ratioReal * ratioReal + ratioImag * ratioImag)
let beSign: Double = ratioImag >= 0 ? +1 : -1

let beSec = (2.0 / (.pi * fHz)) * atan(ratioMag) * beSign
let beMs = beSec * 1000.0

let nominalRates: [(name: String, hz: Double)] = [
    ("18000", 5.0), ("19800", 5.5), ("21600", 6.0),
    ("25200", 7.0), ("28800", 8.0), ("36000", 10.0),
]
let nearest = nominalRates.min { abs($0.hz - fHz) < abs($1.hz - fHz) }!
let rateErrPerDay = (fHz / nearest.hz - 1.0) * 86400.0

print("")
print("  --- Direct FFT measurements ---")
print("  Rate:       \(String(format: "%+.1f", rateErrPerDay)) s/day vs \(nearest.name) bph (\(String(format: "%.4f", fHz)) Hz)")
print("  BE (FFT):   \(String(format: "%+.3f", beMs)) ms    [from |c(f/2)| / |c(f)| = \(String(format: "%.3f", ratioMag)),  sign from arg(c_1/c_2)]")
print("  c_1 / c_2:  \(String(format: "%+.4f", ratioReal)) + \(String(format: "%+.4f", ratioImag))i   (theory: pure imaginary for δ-pulse model)")

// MARK: - 5b. Multi-harmonic δ extraction (Tim's Q3, simpler closed-form)
//
// For symmetric tick=tock with arbitrary internal shape S(f), each harmonic
// h of f_full = f_beat/2 has coefficient:
//   c_h = (1/T_full) · exp(-2πi·h·f_full·p_T) · S(h·f_full) · bracket(h)
// where bracket(even) = 2·cos(γ_h)·exp(-iγ_h)
//       bracket(odd)  = 2·sin(γ_h)·exp(-iγ_h + iπ/2)
//   and γ_h = π·h·f_full·δ = (π·h·δ·f_beat) / 2.
//
// For small δ, bracket(even) ≈ 2 and bracket(odd) ≈ 2·γ_h. So:
//   |c_{2k}|     ≈ 2·|S(2k·f_full)|         (the "shape" envelope at even h)
//   |c_{2k-1}|   ≈ 2·|sin(γ_{2k-1})|·|S((2k-1)·f_full)|  (odd h carries δ)
//
// We don't know |S| at odd-h directly. Approximation: for typical decaying
// tick spectra, log|S(f)| is roughly linear in f over short ranges. So
// interpolate log|S| linearly between adjacent even-h samples to get
// |S| at odd-h, then solve for γ_h, then δ_h = 2γ_h / (π·h·f_beat).
//
// Average across multiple odd-h estimates, weighted by |c_h| (signal-to-
// noise — bigger |c_h| means more reliable γ extraction).

let cByLabel: [String: Harmonic] = Dictionary(uniqueKeysWithValues: harmonics.map { ($0.label, $0) })

func magS(at h: Int) -> Double {
    // h = harmonic index of f_full. Even h: S ≈ |c_h|/2. Odd h: log-interp.
    let label: (Int) -> String = { hi in
        switch hi {
        case 1: return "f/2"; case 2: return "f"; case 3: return "3f/2"
        case 4: return "2f"; case 5: return "5f/2"; case 6: return "3f"
        case 7: return "7f/2"; case 8: return "4f"
        default: return ""
        }
    }
    if h % 2 == 0 {
        return (cByLabel[label(h)]?.mag ?? 0) / 2.0
    } else {
        let mLeftMag = (cByLabel[label(h - 1)]?.mag ?? 0) / 2.0
        let mRightMag = (cByLabel[label(h + 1)]?.mag ?? 0) / 2.0
        if mLeftMag > 0 && mRightMag > 0 {
            return sqrt(mLeftMag * mRightMag)  // geometric mean = log-linear interp
        }
        return max(mLeftMag, mRightMag)
    }
}

print("")
print("  --- Multi-harmonic δ extraction (per odd harmonic) ---")
print("  h  |c_h|        |S_h|approx  |c|/(2|S|)  γ_h(rad)   δ_h(ms)    weight")
var deltaSum = 0.0
var deltaWeightSum = 0.0
let oddHs = [1, 3, 5, 7]
for h in oddHs {
    let label = h == 1 ? "f/2" : h == 3 ? "3f/2" : h == 5 ? "5f/2" : "7f/2"
    let mC = cByLabel[label]?.mag ?? 0
    let mS = magS(at: h)
    if mS <= 0 || mC <= 0 { continue }
    let argSin = min(0.999, mC / (2 * mS))
    let gammaH = asin(argSin)
    let deltaH_sec = 2.0 * gammaH / (.pi * Double(h) * fHz)
    let deltaH_ms = deltaH_sec * 1000.0
    let weight = mC  // weight by signal strength
    deltaSum += deltaH_ms * weight
    deltaWeightSum += weight
    print("  \(h)  \(String(format: "%.6f", mC))  \(String(format: "%.6f", mS))   \(String(format: "%.4f", argSin))     \(String(format: "%.4f", gammaH))   \(String(format: "%+.3f", deltaH_ms))   \(String(format: "%.6f", weight))")
}
let deltaWeighted = deltaWeightSum > 0 ? deltaSum / deltaWeightSum : 0
// Sign from c_1's relationship to c_2 (already computed as ratioImag).
let deltaSigned = deltaWeighted * (ratioImag >= 0 ? +1.0 : -1.0)
print("  Weighted-mean δ (multi-harmonic): \(String(format: "%+.3f", deltaSigned)) ms")

// MARK: - 5c. Full-fit symmetric model via Nelder-Mead simplex
//
// Parameters: (t_2, t_3, A_2, A_3, δ, p_T) — 6 unknowns. Tick has three
// sub-events at offsets (0, t_2, t_3) with amplitudes (1, A_2, A_3); tock
// is the same shape, offset by 1/f_beat + δ. Position p_T is a global
// phase reference. Predicted Fourier coefficients at harmonics 1..8 of
// f_full = f_beat/2 are evaluated in closed form, and squared error against
// the observed coefficients (real+imag, 16 numbers) is minimized.

func predictC(h: Int, fHz: Double, t2: Double, t3: Double, A2: Double, A3: Double, delta: Double, pT: Double) -> (Double, Double) {
    let fFull = fHz / 2.0
    // Tick contributions at p_T + {0, t2, t3} with amplitudes 1, A2, A3.
    // Tock contributions at p_T + 1/fHz + delta + {0, t2, t3} with same amps.
    let arg0 = -2 * .pi * Double(h) * fFull
    var re = 0.0
    var im = 0.0
    // Tick:
    for (amp, off) in [(1.0, 0.0), (A2, t2), (A3, t3)] {
        let phase = arg0 * (pT + off)
        re += amp * cos(phase)
        im += amp * sin(phase)
    }
    // Tock:
    let tockBase = pT + 1.0 / fHz + delta
    for (amp, off) in [(1.0, 0.0), (A2, t2), (A3, t3)] {
        let phase = arg0 * (tockBase + off)
        re += amp * cos(phase)
        im += amp * sin(phase)
    }
    return (re, im)
}

func fitObjective(_ p: [Double]) -> Double {
    let t2 = p[0], t3 = p[1], A2 = p[2], A3 = p[3], delta = p[4], pT = p[5]
    // Bound penalties to keep the search physical.
    var penalty = 0.0
    if A2 < 0 || A2 > 5 { penalty += 1e6 * A2 * A2 }
    if A3 < 0 || A3 > 5 { penalty += 1e6 * A3 * A3 }
    if abs(t2) > 0.05 { penalty += 1e6 * t2 * t2 }
    if abs(t3) > 0.05 { penalty += 1e6 * t3 * t3 }
    if abs(delta) > 0.05 { penalty += 1e6 * delta * delta }

    var sse = 0.0
    let hLabels = [(1, "f/2"), (2, "f"), (3, "3f/2"), (4, "2f"),
                   (5, "5f/2"), (6, "3f"), (7, "7f/2"), (8, "4f")]
    // Determine an overall amplitude scale by matching |c_2|.
    let (re2, im2) = predictC(h: 2, fHz: fHz, t2: t2, t3: t3, A2: A2, A3: A3, delta: delta, pT: pT)
    let predMag2 = sqrt(re2 * re2 + im2 * im2)
    let obsMag2 = cByLabel["f"]!.mag
    let scale = predMag2 > 0 ? obsMag2 / predMag2 : 1.0

    // Reference scale: |c_f| (largest harmonic). Normalize all errors by
    // this so SSE is comparable to "unit-magnitude" expectations and not
    // dominated by absolute-amplitude differences.
    let refScale = obsMag2 + 1e-10

    for (h, label) in hLabels {
        let (predRe, predIm) = predictC(h: h, fHz: fHz, t2: t2, t3: t3, A2: A2, A3: A3, delta: delta, pT: pT)
        let scRe = predRe * scale
        let scIm = predIm * scale
        let obs = cByLabel[label]!
        let dRe = (scRe - obs.real) / refScale
        let dIm = (scIm - obs.imag) / refScale
        sse += dRe * dRe + dIm * dIm
    }
    return penalty + sse / Double(hLabels.count)
}

// Nelder-Mead simplex. ~60 lines, no derivative needed.
func nelderMead(_ initial: [Double], steps: [Double], maxIter: Int) -> [Double] {
    let n = initial.count
    var simplex: [[Double]] = [initial]
    for i in 0..<n {
        var v = initial
        v[i] += steps[i]
        simplex.append(v)
    }
    var values = simplex.map { fitObjective($0) }

    let alpha = 1.0   // reflection
    let gamma = 2.0   // expansion
    let rho = 0.5     // contraction
    let sigma = 0.5   // shrink

    for _ in 0..<maxIter {
        // Sort by value.
        let order = (0...n).sorted { values[$0] < values[$1] }
        simplex = order.map { simplex[$0] }
        values = order.map { values[$0] }

        // Convergence check.
        let spread = values.last! - values.first!
        if spread < 1e-8 { break }

        // Centroid of best n.
        var centroid = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for j in 0..<n { centroid[j] += simplex[i][j] / Double(n) }
        }

        // Reflect.
        var reflected = [Double](repeating: 0, count: n)
        for j in 0..<n { reflected[j] = centroid[j] + alpha * (centroid[j] - simplex[n][j]) }
        let rValue = fitObjective(reflected)

        if rValue < values[0] {
            // Try expansion.
            var expanded = [Double](repeating: 0, count: n)
            for j in 0..<n { expanded[j] = centroid[j] + gamma * (reflected[j] - centroid[j]) }
            let eValue = fitObjective(expanded)
            if eValue < rValue { simplex[n] = expanded; values[n] = eValue }
            else { simplex[n] = reflected; values[n] = rValue }
        } else if rValue < values[n - 1] {
            simplex[n] = reflected; values[n] = rValue
        } else {
            // Contract.
            var contracted = [Double](repeating: 0, count: n)
            for j in 0..<n { contracted[j] = centroid[j] + rho * (simplex[n][j] - centroid[j]) }
            let cValue = fitObjective(contracted)
            if cValue < values[n] {
                simplex[n] = contracted; values[n] = cValue
            } else {
                // Shrink.
                for i in 1...n {
                    for j in 0..<n { simplex[i][j] = simplex[0][j] + sigma * (simplex[i][j] - simplex[0][j]) }
                    values[i] = fitObjective(simplex[i])
                }
            }
        }
    }
    return simplex[0]
}

// Initial guess: small sub-events at +5 ms and +12 ms (typical Swiss),
// δ = 0, p_T = 0. Run from a few starts to avoid local minima.
let starts: [[Double]] = [
    [0.005, 0.012, 0.5, 0.3, 0.0, 0.0],
    [-0.005, -0.010, 0.5, 0.3, 0.005, 0.0],
    [0.008, 0.015, 0.7, 0.5, -0.005, 0.0],
    [-0.008, -0.015, 0.7, 0.5, 0.0, 0.05],
]
// Per-parameter step sizes for the simplex: (t_2, t_3, A_2, A_3, δ, p_T)
// in physical units (seconds, dimensionless, seconds, seconds). Big enough
// to cross local minima but within the bound penalties.
let nmSteps: [Double] = [0.010, 0.015, 0.3, 0.3, 0.015, 0.080]
var bestParams: [Double] = starts[0]
var bestObj = Double.infinity
let dbg = ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_NM"] != nil
for (i, s) in starts.enumerated() {
    let p = nelderMead(s, steps: nmSteps, maxIter: 5000)
    let obj = fitObjective(p)
    if dbg {
        FileHandle.standardError.write("  start \(i): obj=\(String(format: "%.3e", obj))  δ=\(String(format: "%+.3f", p[4] * 1000)) ms  t2=\(String(format: "%+.3f", p[0] * 1000)) t3=\(String(format: "%+.3f", p[1] * 1000)) A2=\(String(format: "%.3f", p[2])) A3=\(String(format: "%.3f", p[3]))\n".data(using: .utf8)!)
    }
    if obj < bestObj { bestObj = obj; bestParams = p }
}

let fitT2 = bestParams[0] * 1000.0
let fitT3 = bestParams[1] * 1000.0
let fitA2 = bestParams[2]
let fitA3 = bestParams[3]
let fitDelta = bestParams[4] * 1000.0
let fitPT = bestParams[5] * 1000.0

print("")
print("  --- Full Nelder-Mead fit (symmetric tick=tock with 3 sub-events) ---")
print("  Sub-event 2:  offset=\(String(format: "%+.3f", fitT2)) ms,  amplitude=\(String(format: "%.3f", fitA2))")
print("  Sub-event 3:  offset=\(String(format: "%+.3f", fitT3)) ms,  amplitude=\(String(format: "%.3f", fitA3))")
print("  δ (BE):       \(String(format: "%+.3f", fitDelta)) ms")
print("  p_T:          \(String(format: "%+.3f", fitPT)) ms")
print("  Final SSE:    \(String(format: "%.6e", bestObj))")

// MARK: - 5d. Full asymmetric fit (tick ≠ tock)
//
// Model: tick has sub-events (0, t_2, t_3) with amplitudes (1, A_2, A_3).
// Tock has sub-events (0, t_2', t_3') with amplitudes (B_1, B_2', B_3').
// Tock dominant peak is offset from tick dominant peak by 1/f_beat + δ.
// 11 parameters total: t_2, t_3, A_2, A_3, t_2', t_3', B_1, B_2', B_3',
// δ, p_T. Fit to 16 observations (8 complex c_h).

func predictAsymC(h: Int, fHz: Double, p: [Double]) -> (Double, Double) {
    // p = [t_2, t_3, A_2, A_3, t_2p, t_3p, B_1, B_2p, B_3p, delta, pT]
    let fFull = fHz / 2.0
    let arg0 = -2 * .pi * Double(h) * fFull
    var re = 0.0, im = 0.0
    // Tick:
    for (amp, off) in [(1.0, 0.0), (p[2], p[0]), (p[3], p[1])] {
        let phase = arg0 * (p[10] + off)
        re += amp * cos(phase)
        im += amp * sin(phase)
    }
    // Tock:
    let tockBase = p[10] + 1.0 / fHz + p[9]
    for (amp, off) in [(p[6], 0.0), (p[7], p[4]), (p[8], p[5])] {
        let phase = arg0 * (tockBase + off)
        re += amp * cos(phase)
        im += amp * sin(phase)
    }
    return (re, im)
}

func asymObjective(_ p: [Double]) -> Double {
    // Bound penalties: positions within ±50 ms, amplitudes 0..5, δ ±50 ms.
    var penalty = 0.0
    let positionBound = 0.050
    let ampBound = 5.0
    for i in [0, 1, 4, 5] {
        if abs(p[i]) > positionBound { penalty += 1e6 * p[i] * p[i] }
    }
    for i in [2, 3, 6, 7, 8] {
        if p[i] < 0 { penalty += 1e6 * p[i] * p[i] }
        if p[i] > ampBound { penalty += 1e6 * p[i] * p[i] }
    }
    if abs(p[9]) > 0.05 { penalty += 1e6 * p[9] * p[9] }

    var sse = 0.0
    let hLabels = [(1, "f/2"), (2, "f"), (3, "3f/2"), (4, "2f"),
                   (5, "5f/2"), (6, "3f"), (7, "7f/2"), (8, "4f")]
    let (re2, im2) = predictAsymC(h: 2, fHz: fHz, p: p)
    let predMag2 = sqrt(re2 * re2 + im2 * im2)
    let obsMag2 = cByLabel["f"]!.mag
    let scale = predMag2 > 0 ? obsMag2 / predMag2 : 1.0
    let refScale = obsMag2 + 1e-10

    for (h, label) in hLabels {
        let (predRe, predIm) = predictAsymC(h: h, fHz: fHz, p: p)
        let dRe = (predRe * scale - cByLabel[label]!.real) / refScale
        let dIm = (predIm * scale - cByLabel[label]!.imag) / refScale
        sse += dRe * dRe + dIm * dIm
    }
    return penalty + sse / Double(hLabels.count)
}

func nelderMeadAsym(_ initial: [Double], steps: [Double], maxIter: Int) -> [Double] {
    let n = initial.count
    var simplex: [[Double]] = [initial]
    for i in 0..<n {
        var v = initial
        v[i] += steps[i]
        simplex.append(v)
    }
    var values = simplex.map { asymObjective($0) }
    let alpha = 1.0, gamma = 2.0, rho = 0.5, sigma = 0.5

    for _ in 0..<maxIter {
        let order = (0...n).sorted { values[$0] < values[$1] }
        simplex = order.map { simplex[$0] }
        values = order.map { values[$0] }
        if values.last! - values.first! < 1e-10 { break }

        var centroid = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for j in 0..<n { centroid[j] += simplex[i][j] / Double(n) }
        }
        var reflected = [Double](repeating: 0, count: n)
        for j in 0..<n { reflected[j] = centroid[j] + alpha * (centroid[j] - simplex[n][j]) }
        let rValue = asymObjective(reflected)

        if rValue < values[0] {
            var expanded = [Double](repeating: 0, count: n)
            for j in 0..<n { expanded[j] = centroid[j] + gamma * (reflected[j] - centroid[j]) }
            let eValue = asymObjective(expanded)
            if eValue < rValue { simplex[n] = expanded; values[n] = eValue }
            else { simplex[n] = reflected; values[n] = rValue }
        } else if rValue < values[n - 1] {
            simplex[n] = reflected; values[n] = rValue
        } else {
            var contracted = [Double](repeating: 0, count: n)
            for j in 0..<n { contracted[j] = centroid[j] + rho * (simplex[n][j] - centroid[j]) }
            let cValue = asymObjective(contracted)
            if cValue < values[n] {
                simplex[n] = contracted; values[n] = cValue
            } else {
                for i in 1...n {
                    for j in 0..<n { simplex[i][j] = simplex[0][j] + sigma * (simplex[i][j] - simplex[0][j]) }
                    values[i] = asymObjective(simplex[i])
                }
            }
        }
    }
    return simplex[0]
}

// Seed asym fit from symmetric fit's best parameters.
let asymInit: [Double] = [
    bestParams[0],  // t_2
    bestParams[1],  // t_3
    bestParams[2],  // A_2
    bestParams[3],  // A_3
    bestParams[0],  // t_2' (start same as tick)
    bestParams[1],  // t_3'
    1.0,            // B_1 (start: same dominant amplitude)
    bestParams[2],  // B_2'
    bestParams[3],  // B_3'
    bestParams[4],  // δ
    bestParams[5],  // p_T
]
let asymSteps: [Double] = [0.005, 0.005, 0.15, 0.15, 0.005, 0.005, 0.2, 0.15, 0.15, 0.008, 0.030]

// Multi-start with perturbations of the symmetric solution.
var asymBestParams = asymInit
var asymBestObj = Double.infinity
for trial in 0..<6 {
    var start = asymInit
    if trial > 0 {
        // Randomize tock parameters to break tick=tock symmetry.
        let rng = Double(trial) * 0.7
        start[4] += sin(rng * 1.3) * 0.005
        start[5] += sin(rng * 1.7) * 0.005
        start[6] += sin(rng * 2.1) * 0.3
        start[7] += sin(rng * 2.7) * 0.15
        start[8] += sin(rng * 3.1) * 0.15
        start[9] += sin(rng * 4.0) * 0.005
    }
    let p = nelderMeadAsym(start, steps: asymSteps, maxIter: 8000)
    let obj = asymObjective(p)
    if obj < asymBestObj { asymBestObj = obj; asymBestParams = p }
}

print("")
print("  --- Asymmetric tick≠tock fit (Nelder-Mead, 11 params) ---")
print("  Tick sub-events:  (0, \(String(format: "%+.2f", asymBestParams[0]*1000)), \(String(format: "%+.2f", asymBestParams[1]*1000))) ms   amps (1, \(String(format: "%.3f", asymBestParams[2])), \(String(format: "%.3f", asymBestParams[3])))")
print("  Tock sub-events:  (0, \(String(format: "%+.2f", asymBestParams[4]*1000)), \(String(format: "%+.2f", asymBestParams[5]*1000))) ms   amps (\(String(format: "%.3f", asymBestParams[6])), \(String(format: "%.3f", asymBestParams[7])), \(String(format: "%.3f", asymBestParams[8])))")
print("  δ (BE):           \(String(format: "%+.3f", asymBestParams[9]*1000)) ms")
print("  Final SSE:        \(String(format: "%.6e", asymBestObj))")

// MARK: - 6. Sub-event structure from harmonics 2f, 3f, ...
//
// Each higher harmonic of the BEAT rate (n·f_beat = 2n·f_half for even n
// in our half-cycle bookkeeping) encodes the shape of one beat. If the
// beat has sub-events at relative offsets {0, t_2, t_3} with amplitudes
// {1, A_2, A_3}, then the n-th harmonic of f_beat has Fourier coefficient:
//   c_{2n} ∝ exp(-2πi·n·f_beat·t_T) · [1 + A_2·exp(-2πi·n·f_beat·t_2) + A_3·exp(-2πi·n·f_beat·t_3)]
// (ignoring BE for clarity)
//
// The phase of (c_{2n} / c_{2}) tells us the "extra phase per harmonic" —
// i.e., where, within one beat, the n-th harmonic of the shape lives.
// Linear phase progression across harmonics → all sub-events at the same
// position (degenerate single-peak case). Non-linear phase progression
// → multiple sub-events at different positions. The PATTERN of c_{2n}/c_{2}
// is a Fourier-series signature of the per-beat shape.

print("")
print("  Per-beat shape (from harmonics):")
print("  c(2f) / c(f):  ratio mag=\(String(format: "%.3f", harmonics[3].mag / cF.mag)),  rel phase=\(String(format: "%+.3f", harmonics[3].phase - cF.phase)) rad")
print("  c(3f) / c(f):  ratio mag=\(String(format: "%.3f", harmonics[5].mag / cF.mag)),  rel phase=\(String(format: "%+.3f", harmonics[5].phase - cF.phase)) rad")
print("  c(4f) / c(f):  ratio mag=\(String(format: "%.3f", harmonics[7].mag / cF.mag)),  rel phase=\(String(format: "%+.3f", harmonics[7].phase - cF.phase)) rad")
print("")
print("  3f/2 ÷ f:  \(String(format: "%.3f", harmonics[2].mag / cF.mag))  (should be small if S_T ≈ S_C; large if tick & tock differ in shape)")
print("  5f/2 ÷ f:  \(String(format: "%.3f", harmonics[4].mag / cF.mag))")
print("  7f/2 ÷ f:  \(String(format: "%.3f", harmonics[6].mag / cF.mag))")

// MARK: - 7. JSON output

struct Output: Encodable {
    struct H: Encodable {
        let label: String
        let hz: Double
        let magnitude: Double
        let phase: Double
        let real: Double
        let imag: Double
    }
    let fileName: String
    let durationSec: Double
    let truncSec: Double
    let halfCycles: Int
    let fHz: Double
    let nearestRateName: String
    let rateErrPerDay: Double
    let beMsFromFFT: Double
    let cHalfOverF: [Double]  // [real, imag]
    let harmonics: [H]
}

let out = Output(
    fileName: fileName,
    durationSec: Double(buffer.samples.count) / sampleRate,
    truncSec: Double(truncSamples) / envRate,
    halfCycles: halfCycles,
    fHz: fHz,
    nearestRateName: nearest.name,
    rateErrPerDay: rateErrPerDay,
    beMsFromFFT: beMs,
    cHalfOverF: [ratioReal, ratioImag],
    harmonics: harmonics.map { Output.H(label: $0.label, hz: $0.hz, magnitude: $0.mag, phase: $0.phase, real: $0.real, imag: $0.imag) }
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let outURL = url.deletingPathExtension().appendingPathExtension("fourier.json")
do {
    try encoder.encode(out).write(to: outURL)
    print("")
    print("  wrote \(outURL.path)")
} catch {
    print("Error writing JSON: \(error)")
}
