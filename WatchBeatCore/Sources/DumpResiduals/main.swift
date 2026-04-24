import Foundation
import WatchBeatCore

// Run the full measurement pipeline on one WAV and print per-tick residuals.
// Also bin them to see if outliers cluster near ±½-period (sub-click mis-localization).

guard CommandLine.arguments.count >= 2 else {
    print("usage: DumpResiduals <file.wav> [--csv]")
    exit(1)
}

let path = CommandLine.arguments[1]
let emitCSV = CommandLine.arguments.contains("--csv")
let url = URL(fileURLWithPath: path)
guard let buffer = try? WAVReader.read(url: url) else {
    print("failed to read \(path)")
    exit(1)
}

let pipeline = MeasurementPipeline()
let result = pipeline.measure(buffer)

// Also run forced 18000 to see candidate's view (useful in tiebreak mode)
let rateArgs: [(String, StandardBeatRate)] = [("--force18",.bph18000),("--force198",.bph19800),("--force216",.bph21600),("--force252",.bph25200),("--force288",.bph28800),("--force360",.bph36000)]
for (flag, r) in rateArgs where CommandLine.arguments.contains(flag) {
    let forced2 = pipeline.measure(buffer, knownRate: r)
    let ee = forced2.tickTimings.filter{$0.isEvenBeat}.map{$0.residualMs}
    let oo = forced2.tickTimings.filter{!$0.isEvenBeat}.map{$0.residualMs}
    func os(_ xs:[Double])->Double {let p=xs.filter{$0>0}.count;let f=Double(p)/Double(xs.count);return max(f,1-f)}
    print(String(format:"[force %d] q=%d%% ticks=%d | EVEN n=%d os=%.2f sd=%.2f | ODD n=%d os=%.2f sd=%.2f",
        r.rawValue, Int(forced2.qualityScore*100), forced2.tickCount,
        ee.count, ee.isEmpty ? 0 : os(ee), ee.isEmpty ? 0 : sqrt(ee.map{($0-ee.reduce(0,+)/Double(ee.count))*($0-ee.reduce(0,+)/Double(ee.count))}.reduce(0,+)/Double(ee.count)),
        oo.count, oo.isEmpty ? 0 : os(oo), oo.isEmpty ? 0 : sqrt(oo.map{($0-oo.reduce(0,+)/Double(oo.count))*($0-oo.reduce(0,+)/Double(oo.count))}.reduce(0,+)/Double(oo.count))))
}

if false {
    let forced = pipeline.measure(buffer, knownRate: .bph18000)
    print("[forced 18000] rate=\(forced.snappedRate.rawValue) q=\(Int(forced.qualityScore*100))% ticks=\(forced.tickCount) rateErr=\(String(format: "%+.1f", forced.rateErrorSecondsPerDay)) beatErr=\(forced.beatErrorMilliseconds.map{String(format: "%.2fms",$0)} ?? "—")")
    let ampEst = AmplitudeEstimator()
    let pw = ampEst.measurePulseWidths(input: buffer, rate: forced.snappedRate, rateErrorSecondsPerDay: forced.rateErrorSecondsPerDay, tickTimings: forced.tickTimings)
    let amp = AmplitudeEstimator.combinedAmplitude(pulseWidths: pw, beatRate: forced.snappedRate, rateErrorSecondsPerDay: forced.rateErrorSecondsPerDay, liftAngleDegrees: 52)
    print("[forced 18000] ampl: tickPulse=\(pw.tickPulseMs.map{String(format: "%.2fms", $0)} ?? "—") tockPulse=\(pw.tockPulseMs.map{String(format: "%.2fms", $0)} ?? "—") folds=\(pw.foldCount) amp@52°=\(amp.map{String(format: "%.0f°",$0)} ?? "—")")
    let ts = forced.tickTimings.map{$0.residualMs}.sorted()
    if !ts.isEmpty {
        print("[forced 18000] residuals min=\(String(format: "%+.2f",ts.first!)) med=\(String(format: "%+.2f",ts[ts.count/2])) max=\(String(format: "%+.2f",ts.last!))")
    }
}

let periodMs = result.snappedRate.nominalPeriodSeconds * 1000.0
let halfPeriodMs = periodMs / 2.0

print("file=\(url.lastPathComponent)")
print("rate=\(result.snappedRate.rawValue) bph  period=\(String(format: "%.2f", periodMs)) ms  halfPeriod=\(String(format: "%.2f", halfPeriodMs)) ms")
print("rateError=\(String(format: "%+.1f", result.rateErrorSecondsPerDay)) s/day  beatError=\(result.beatErrorMilliseconds.map { String(format: "%.2f ms", $0) } ?? "—")")
print("quality=\(Int(result.qualityScore * 100))%  ticks=\(result.tickCount)  disorderly=\(result.isDisorderly)")

// Amplitude probe — use amplitudeTickTimings (diverges from tickTimings in tiebreak)
let ampEst = AmplitudeEstimator()
let pw = ampEst.measurePulseWidths(
    input: buffer,
    rate: result.snappedRate,
    rateErrorSecondsPerDay: result.rateErrorSecondsPerDay,
    tickTimings: result.amplitudeTickTimings
)
let liftDeg = 52.0
let amp = AmplitudeEstimator.combinedAmplitude(
    pulseWidths: pw,
    beatRate: result.snappedRate,
    rateErrorSecondsPerDay: result.rateErrorSecondsPerDay,
    liftAngleDegrees: liftDeg
)
let tickStr = pw.tickPulseMs.map { String(format: "%.2f", $0) } ?? "—"
let tockStr = pw.tockPulseMs.map { String(format: "%.2f", $0) } ?? "—"
let ampStr = amp.map { String(format: "%.0f°", $0) } ?? "—"
print("amplitude: tickPulse=\(tickStr)ms  tockPulse=\(tockStr)ms  folds=\(pw.foldCount)  amp@52°=\(ampStr)")

let timings = result.tickTimings
if timings.isEmpty {
    print("no tick timings — nothing to analyze")
    exit(0)
}

let residuals = timings.map { $0.residualMs }
let sorted = residuals.sorted()
let med = sorted[sorted.count / 2]
let p5 = sorted[sorted.count * 5 / 100]
let p95 = sorted[sorted.count * 95 / 100]
let minR = sorted.first!
let maxR = sorted.last!

print("\nResidual summary (ms): min=\(String(format: "%.2f", minR))  p5=\(String(format: "%.2f", p5))  med=\(String(format: "%.2f", med))  p95=\(String(format: "%.2f", p95))  max=\(String(format: "%.2f", maxR))")

// Threshold for "outlier": > quarter of a period from the line
let outlierThresh = periodMs / 4.0
let outliers = timings.filter { abs($0.residualMs) > outlierThresh }
print("outliers (|res| > period/4 = \(String(format: "%.1f", outlierThresh)) ms): \(outliers.count) of \(timings.count) = \(String(format: "%.1f", Double(outliers.count) / Double(timings.count) * 100))%")

// How close are outliers to ±half-period?
if !outliers.isEmpty {
    let distsFromHalf = outliers.map { abs(abs($0.residualMs) - halfPeriodMs) }
    let dSorted = distsFromHalf.sorted()
    let dMed = dSorted[dSorted.count / 2]
    let within5 = distsFromHalf.filter { $0 < 5.0 }.count
    let within10 = distsFromHalf.filter { $0 < 10.0 }.count
    print("outlier |residual| distance from halfPeriod (\(String(format: "%.1f", halfPeriodMs)) ms):")
    print("  median=\(String(format: "%.2f", dMed)) ms   within 5ms: \(within5)/\(outliers.count)   within 10ms: \(within10)/\(outliers.count)")
}

// Histogram of residuals in the full range [-period/2, +period/2]
let nBins = 40
let lo = -halfPeriodMs
let hi = halfPeriodMs
var bins = [Int](repeating: 0, count: nBins)
for r in residuals {
    // Fold into [-half, +half] like the timegraph wraps
    var w = r
    while w > halfPeriodMs { w -= periodMs }
    while w < -halfPeriodMs { w += periodMs }
    let idx = max(0, min(nBins - 1, Int((w - lo) / (hi - lo) * Double(nBins))))
    bins[idx] += 1
}
print("\nHistogram of residuals wrapped to [-period/2, +period/2]:")
let maxBin = bins.max() ?? 1
let width = 50
for (i, c) in bins.enumerated() {
    let lb = lo + (hi - lo) * Double(i) / Double(nBins)
    let ub = lo + (hi - lo) * Double(i + 1) / Double(nBins)
    let barLen = c == 0 ? 0 : max(1, c * width / maxBin)
    let bar = String(repeating: "#", count: barLen)
    print(String(format: "%+6.1f..%+6.1f  %4d  %@", lb, ub, c, bar))
}

// Outlier details
if !outliers.isEmpty {
    print("\nTop 20 outliers (beatIdx, isEven, residualMs, dist-from-halfPeriod):")
    let byAbs = timings.sorted { abs($0.residualMs) > abs($1.residualMs) }
    for t in byAbs.prefix(20) {
        let distHalf = abs(abs(t.residualMs) - halfPeriodMs)
        print(String(format: "  beat=%5d  %@  res=%+7.2f ms   |res|-½p=%+6.2f", t.beatIndex, t.isEvenBeat ? "EVEN" : "odd ", t.residualMs, abs(t.residualMs) - halfPeriodMs))
        _ = distHalf
    }
}

// Split by parity
let even = timings.filter { $0.isEvenBeat }.map { $0.residualMs }
let odd = timings.filter { !$0.isEvenBeat }.map { $0.residualMs }
func stats(_ xs: [Double]) -> String {
    guard !xs.isEmpty else { return "n=0" }
    let s = xs.sorted()
    let med = s[s.count / 2]
    let p5 = s[max(0, s.count * 5 / 100)]
    let p95 = s[min(s.count - 1, s.count * 95 / 100)]
    let mean = xs.reduce(0, +) / Double(xs.count)
    let varr = xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(xs.count)
    let sd = sqrt(varr)
    return String(format: "n=%d  med=%+.2f  mean=%+.2f  sd=%.2f  min=%+.2f  p5=%+.2f  p95=%+.2f  max=%+.2f",
                  xs.count, med, mean, sd, s.first!, p5, p95, s.last!)
}
print("\nEVEN (blue/tick): \(stats(even))")
print("ODD  (cyan/tock): \(stats(odd))")

// Print largest |residual| entries to see which beats are the strays
print("\nTop 15 largest |residual|:")
let byAbs = timings.sorted { abs($0.residualMs) > abs($1.residualMs) }
for t in byAbs.prefix(15) {
    print(String(format: "  beat=%5d  %@  res=%+7.2f ms",
                 t.beatIndex,
                 t.isEvenBeat ? "EVEN" : "odd ",
                 t.residualMs))
}

// Show the full sorted residual list inline
print("\nAll residuals sorted (ms):")
for (i, r) in residuals.sorted().enumerated() {
    if i % 8 == 0 { print("", terminator: "  ") }
    print(String(format: "%+6.2f", r), terminator: " ")
    if i % 8 == 7 { print("") }
}
print("")

if emitCSV {
    let outURL = url.deletingPathExtension().appendingPathExtension("residuals.csv")
    var s = "beatIndex,isEvenBeat,residualMs\n"
    for t in timings { s += "\(t.beatIndex),\(t.isEvenBeat),\(t.residualMs)\n" }
    try? s.write(to: outURL, atomically: true, encoding: .utf8)
    print("\nwrote \(outURL.lastPathComponent)")
}
