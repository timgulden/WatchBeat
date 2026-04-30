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
