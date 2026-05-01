import Foundation
import Accelerate
import WatchBeatCore

// Usage: swift run AnalyzeSamples <path-to-wav>
// For each beat, locate the main envelope peak and count secondary peaks
// WITHIN ±3 ms of the main. A high fraction of ticks with a near-equal
// secondary peak inside this window is the fingerprint of picker wobble.

let arg = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "../SoundSamples/Timex1CrownUp_18000bph_q98.wav"
let url = URL(fileURLWithPath: arg)

guard let buffer = try? WAVReader.read(url: url) else {
    print("Could not read \(arg)"); exit(1)
}

let sr = buffer.sampleRate
let raw = buffer.samples
print("=== \(url.lastPathComponent) ===")

let pipeline = MeasurementPipeline()
let useReference = ProcessInfo.processInfo.environment["WATCHBEAT_REFERENCE"] != nil
let (result, _) = useReference
    ? pipeline.measureReferenceWithDiagnostics(buffer)
    : pipeline.measureWithDiagnostics(buffer)
print(String(format: "%@Rate %d bph  err %+.1f s/day  beatErr %@  q=%.1f%%  conf=%.0f%%  lowConf=%@",
             useReference ? "[REF] " : "",
             result.snappedRate.rawValue,
             result.rateErrorSecondsPerDay,
             result.beatErrorMilliseconds.map { String(format: "%.2f ms", $0) } ?? "nil",
             result.qualityScore * 100,
             result.confirmedFraction * 100,
             result.isLowConfidence ? "Y" : "N"))

// Amplitude flow (matches iOS app pipeline): measurePulseWidths → combinedAmplitude.
// Default lift angle 52° (Omega 485). Override with WATCHBEAT_LIFT_ANGLE env var.
let liftAngle = Double(ProcessInfo.processInfo.environment["WATCHBEAT_LIFT_ANGLE"] ?? "") ?? 52.0
let amplitudeEstimator = AmplitudeEstimator()
let pulseWidths = amplitudeEstimator.measurePulseWidths(
    input: buffer,
    rate: result.snappedRate,
    rateErrorSecondsPerDay: result.rateErrorSecondsPerDay,
    tickTimings: result.amplitudeTickTimings
)
let amp = AmplitudeEstimator.combinedAmplitude(
    pulseWidths: pulseWidths,
    beatRate: result.snappedRate,
    rateErrorSecondsPerDay: result.rateErrorSecondsPerDay,
    liftAngleDegrees: liftAngle
)
print(String(format: "  amplitude: tick_pulse=%@  tock_pulse=%@  folds=%d  combined=%@°  (lift=%.0f°)",
             pulseWidths.tickPulseMs.map { String(format: "%.2f ms", $0) } ?? "nil",
             pulseWidths.tockPulseMs.map { String(format: "%.2f ms", $0) } ?? "nil",
             pulseWidths.foldCount,
             amp.map { String(format: "%.0f", $0) } ?? "nil",
             liftAngle))

// Per-class μ/σ + one-sidedness — direct read of what the disorderly rule sees.
// Also test the "label-flip" hypothesis: split the residuals by beat index
// into early/late halves and check whether the per-class mean changes sign.
// A sign flip means an off-by-one beat assignment somewhere in the window —
// after which "tick" is physically a tock and vice versa.
do {
    func stats(_ xs: [Double]) -> (mean: Double, sd: Double, oneSided: Double) {
        guard xs.count > 1 else { return (0, 0, 1) }
        let m = xs.reduce(0, +) / Double(xs.count)
        let v = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
        let pos = Double(xs.filter { $0 > 0 }.count) / Double(xs.count)
        return (m, sqrt(v), max(pos, 1 - pos))
    }
    let timings = result.tickTimings.sorted(by: { $0.beatIndex < $1.beatIndex })
    let split = timings.count / 2
    let early = Array(timings.prefix(split))
    let late = Array(timings.suffix(timings.count - split))
    let evenAll = timings.filter { $0.isEvenBeat }.map { $0.residualMs }
    let oddAll = timings.filter { !$0.isEvenBeat }.map { $0.residualMs }
    let evenEarly = early.filter { $0.isEvenBeat }.map { $0.residualMs }
    let oddEarly = early.filter { !$0.isEvenBeat }.map { $0.residualMs }
    let evenLate = late.filter { $0.isEvenBeat }.map { $0.residualMs }
    let oddLate = late.filter { !$0.isEvenBeat }.map { $0.residualMs }
    let eA = stats(evenAll), oA = stats(oddAll)
    let eE = stats(evenEarly), oE = stats(oddEarly)
    let eL = stats(evenLate), oL = stats(oddLate)
    print(String(format: "  even: μ=%+.2fms σ=%.2fms 1side=%.2f  (n=%d)  early μ=%+.2f late μ=%+.2f",
                 eA.mean, eA.sd, eA.oneSided, evenAll.count, eE.mean, eL.mean))
    print(String(format: "  odd:  μ=%+.2fms σ=%.2fms 1side=%.2f  (n=%d)  early μ=%+.2f late μ=%+.2f",
                 oA.mean, oA.sd, oA.oneSided, oddAll.count, oE.mean, oL.mean))
    let flip = (eE.mean * eL.mean < 0) || (oE.mean * oL.mean < 0)
    if flip {
        print("  *** SIGN FLIP across halves — possible off-by-one label swap ***")
    }

    // Pair-abs σ: the right disorderly metric. Clean watches and label-swap
    // recordings both give tight |even-odd| pair clusters ≈ 2*BE; only true
    // sub-event flipping spreads them out.
    var beatToRes: [Int: Double] = [:]
    for t in timings { beatToRes[t.beatIndex] = t.residualMs }
    var pairAbs: [Double] = []
    for (beat, ev) in beatToRes where beat % 2 == 0 {
        if let od = beatToRes[beat + 1] { pairAbs.append(abs(ev - od)) }
    }
    if pairAbs.count >= 5 {
        let sorted = pairAbs.sorted()
        let median = sorted[sorted.count / 2]
        let absDev = pairAbs.map { abs($0 - median) }.sorted()
        let mad = absDev[absDev.count / 2] * 1.4826  // robust σ
        let mean = pairAbs.reduce(0, +) / Double(pairAbs.count)
        let v = pairAbs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(pairAbs.count - 1)
        let sd = sqrt(v)
        // "Wild" pair count: pairs more than 3·MAD above the median.
        // Sub-event flipping should produce a small number of these.
        let wildThresh = median + 3 * mad
        let wild = pairAbs.filter { $0 > wildThresh }.count
        print(String(format: "  pair-abs:  μ=%.2f  σ=%.2f  median=%.2f  MAD=%.2f  σ/MAD=%.1f  wild=%d/%d",
                     mean, sd, median, mad, sd / max(mad, 0.01), wild, pairAbs.count))
    }
}

// Build the highpass + squared envelope the pipeline operates on.
let conditioner = SignalConditioner()
let hp = conditioner.highpassFilter(raw, sampleRate: sr,
                                    cutoff: MeasurementPipeline.highpassCutoffHz)
var sq = [Float](repeating: 0, count: hp.count)
vDSP_vsq(hp, 1, &sq, 1, vDSP_Length(hp.count))

// 0.2 ms moving-avg smooth — keeps sub-ms structure visible.
let sw = max(1, Int(0.2e-3 * sr))
var env = [Float](repeating: 0, count: sq.count)
var acc: Float = 0
for i in 0..<min(sw, sq.count) { acc += sq[i] }
for i in sw..<sq.count {
    acc += sq[i] - sq[i - sw]
    env[i] = acc / Float(sw)
}

// Walk period-sized windows from the first strong-energy sample and pick
// each window's max. This gives us one tick position per beat.
let period = 3600.0 / Double(result.snappedRate.rawValue)
let periodN = Int(period * sr)
let envMed = env.sorted()[env.count / 2]
var firstStrong = 0
for i in 0..<env.count { if env[i] > envMed * 50 { firstStrong = i; break } }

var tickSamples: [Int] = []
var cursor = firstStrong
let tol = periodN / 4
while cursor < env.count - periodN {
    let lo = max(0, cursor - tol)
    let hi = min(env.count, cursor + periodN + tol)
    var mi = lo; var mv: Float = -1
    for j in lo..<hi { if env[j] > mv { mv = env[j]; mi = j } }
    tickSamples.append(mi)
    cursor = mi + periodN
}
print("Walked \(tickSamples.count) tick positions")

// For each tick, find all prominent peaks within ±3ms of the main peak.
// "Prominent" = within 40% of the main peak amplitude, separated by ≥0.3 ms.
let winMs: Double = 3.0
let winN = Int(winMs * 1e-3 * sr)
let minSepN = max(1, Int(0.3e-3 * sr))

var allSecRatios: [Double] = []
var allSecSeparations: [Double] = []
var multiCount = 0
var peakCountHist: [Int: Int] = [:]

for cs in tickSamples {
    let lo = max(1, cs - winN)
    let hi = min(env.count - 1, cs + winN)
    // Main peak amplitude = max inside ±winMs
    var mv: Float = -1
    for j in lo..<hi { if env[j] > mv { mv = env[j] } }
    // All local maxima in window
    var candidates: [(i: Int, amp: Float)] = []
    for j in (lo+1)..<hi {
        if env[j] > env[j-1] && env[j] >= env[j+1] && env[j] >= mv * 0.4 {
            candidates.append((j, env[j]))
        }
    }
    candidates.sort { $0.amp > $1.amp }
    var kept: [(i: Int, amp: Float)] = []
    for c in candidates where !kept.contains(where: { abs($0.i - c.i) < minSepN }) {
        kept.append(c)
    }
    peakCountHist[kept.count, default: 0] += 1
    if kept.count >= 2 {
        multiCount += 1
        let main = kept[0]
        let sec = kept[1]
        allSecRatios.append(Double(sec.amp / main.amp))
        allSecSeparations.append(Double(sec.i - main.i) / sr * 1000)
    }
}

print(String(format: "\n%d of %d ticks have ≥2 prominent peaks within ±3ms (%.1f%%)",
             multiCount, tickSamples.count,
             Double(multiCount) / Double(max(1, tickSamples.count)) * 100))
print("\nPeak-count histogram (per-tick, ±3ms window):")
for (k, v) in peakCountHist.sorted(by: { $0.key < $1.key }) {
    print(String(format: "  %d peak(s): %3d  %@",
                 k, v, String(repeating: "*", count: v)))
}

// Tick-to-tick peak-amplitude variability: how uniform are the ticks?
var tickPeaks: [Double] = []
for cs in tickSamples {
    let lo = max(0, cs - Int(2e-3 * sr))
    let hi = min(env.count, cs + Int(2e-3 * sr))
    var mv: Float = 0
    for j in lo..<hi { if env[j] > mv { mv = env[j] } }
    tickPeaks.append(Double(mv))
}
// Also background: median of envelope between ticks (≥periodN/3 away from any tick)
var bgSamples: [Float] = []
for cs in tickSamples.dropFirst() {
    let bgCenter = cs - periodN / 2
    let lo = max(0, bgCenter - Int(5e-3 * sr))
    let hi = min(env.count, bgCenter + Int(5e-3 * sr))
    for j in lo..<hi { bgSamples.append(env[j]) }
}
bgSamples.sort()
let bgMedian = bgSamples.isEmpty ? 1.0 : Double(bgSamples[bgSamples.count / 2])
let tpSorted = tickPeaks.sorted()
let tpMedian = tpSorted[tpSorted.count / 2]
let tpMin = tpSorted.first ?? 0
let tpMax = tpSorted.last ?? 0
let tpP10 = tpSorted[max(0, tpSorted.count / 10)]
let tpP90 = tpSorted[min(tpSorted.count - 1, (tpSorted.count * 9) / 10)]
print(String(format: "\nTick peak amplitude (env units):"))
print(String(format: "  median=%.4g  min=%.4g  max=%.4g",
             tpMedian, tpMin, tpMax))
print(String(format: "  p10=%.4g  p90=%.4g  p90/p10=%.2f  max/min=%.2f",
             tpP10, tpP90, tpP90 / max(tpP10, 1e-12), tpMax / max(tpMin, 1e-12)))
print(String(format: "  median tick/background S/N: %.1f×",
             tpMedian / max(bgMedian, 1e-12)))
print(String(format: "  weakest tick / background:   %.1f×",
             tpMin / max(bgMedian, 1e-12)))

if !allSecRatios.isEmpty {
    let ratSorted = allSecRatios.sorted()
    let sepSorted = allSecSeparations.sorted()
    let meanRatio = allSecRatios.reduce(0, +) / Double(allSecRatios.count)
    let medRatio = ratSorted[ratSorted.count / 2]
    let medSep = sepSorted[sepSorted.count / 2]
    print(String(format: "\nSecondary peak — mean amp ratio: %.2f  median: %.2f",
                 meanRatio, medRatio))
    print(String(format: "Secondary peak — median |separation| from main: %.2f ms  range: [%.2f, %.2f]",
                 abs(medSep),
                 allSecSeparations.map { abs($0) }.min() ?? 0,
                 allSecSeparations.map { abs($0) }.max() ?? 0))
}

// Dump residuals in beat order — the most direct view of "disorderly".
// An honest galloping escapement will show a clean ±alternation; a worn
// pivot with random jitter will be noise; a stick-slip or amplitude
// modulation will show a low-frequency wiggle under the alternation.
print("\nResiduals by beat index (ms, tick=T, tock=t):")
for t in result.tickTimings {
    let marker = t.isEvenBeat ? "T" : "t"
    let bars = String(repeating: " ", count: max(0, min(40, 20 + Int(t.residualMs * 4))))
    print(String(format: "  %3d %@ %+.2f%@|", t.beatIndex, marker, t.residualMs, bars))
}

// Adjacent-beat differences: "instantaneous period" minus nominal, ms.
// Galloping shows as ± alternation. Slow wobble shows as smooth drift.
print("\nAdjacent-tick intervals (ms deviation from expected period):")
let sorted = result.tickTimings.sorted { $0.beatIndex < $1.beatIndex }
if sorted.count > 1 {
    for k in 1..<sorted.count {
        let di = sorted[k].beatIndex - sorted[k-1].beatIndex
        let dr = sorted[k].residualMs - sorted[k-1].residualMs
        print(String(format: "  Δidx=%d  Δresid=%+.2f ms", di, dr))
    }
} else {
    print("  (no tickTimings — Reference picker used FFT-rate fallback)")
}
