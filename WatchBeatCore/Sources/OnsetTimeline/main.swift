import Foundation
import WatchBeatCore
import Accelerate

// Diagnostic CLI: dump a JSON timeline of one recording so the trim
// decisions are visually verifiable.
//
// Output JSON:
//   - envelope: 1 kHz-downsampled smoothed-squared signal (15000 floats
//     for a 15 s recording). The same signal the picker sees, just
//     decimated for plot file size.
//   - picks: every confirmed pick from the picker, with kept/trimmed
//     status, beat index, parity, and absolute time.
//   - windowBoundaries: midpoints between consecutive ticks (where the
//     period walk's window edges fall).
//
//   Usage: OnsetTimeline <file.wav> [<output.json>]

guard CommandLine.arguments.count >= 2 else {
    print("usage: OnsetTimeline <file.wav> [<output.json>]")
    exit(1)
}

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
let outPath: String = CommandLine.arguments.count >= 3
    ? CommandLine.arguments[2]
    : url.deletingPathExtension().appendingPathExtension("timeline.json").path

guard let buffer = try? WAVReader.read(url: url) else {
    print("failed to read \(path)")
    exit(1)
}

let pipeline = MeasurementPipeline()

// Run with matched filter (kept ticks only).
let postMF = pipeline.measure(buffer)

// Run without matched filter (every confirmed pick).
setenv("WATCHBEAT_SKIP_MF", "1", 1)
let preMF = pipeline.measure(buffer)
unsetenv("WATCHBEAT_SKIP_MF")

guard let slope = preMF.measuredPeriod, let intercept = preMF.regressionIntercept else {
    print("error: pipeline did not return regression parameters")
    exit(1)
}

// Mark which beat indices survived the matched-filter trim.
let keptIndices = Set(postMF.tickTimings.map { $0.beatIndex })

// Compute envelope: highpass at the primary cutoff, square, smooth at 5 ms,
// downsample to 1 kHz for output. Mirrors what the picker sees.
let conditioner = SignalConditioner()
let hp = conditioner.highpassFilter(buffer.samples, sampleRate: buffer.sampleRate, cutoff: MeasurementPipeline.highpassCutoffHz)
var squared = [Float](repeating: 0, count: hp.count)
vDSP_vsq(hp, 1, &squared, 1, vDSP_Length(hp.count))
let smoothWin = max(3, Int(0.005 * buffer.sampleRate)) | 1
var smoothed = [Float](repeating: 0, count: squared.count)
let kernel = [Float](repeating: 1.0 / Float(smoothWin), count: smoothWin)
vDSP_conv(squared, 1, kernel, 1, &smoothed, 1, vDSP_Length(squared.count - smoothWin + 1), vDSP_Length(smoothWin))

// Downsample smoothed to 1 kHz by max-pooling each 1 ms block. Max-pool
// preserves transient shapes better than mean-pool when the pool window
// is comparable to the transient itself.
let outRate = 1000.0
let blockSamples = Int(buffer.sampleRate / outRate)
let outCount = smoothed.count / blockSamples
var envOut = [Float](repeating: 0, count: outCount)
for k in 0..<outCount {
    let lo = k * blockSamples
    let hi = lo + blockSamples
    var maxVal: Float = 0
    for i in lo..<hi where smoothed[i] > maxVal { maxVal = smoothed[i] }
    envOut[k] = maxVal
}

// Build pick records with absolute times.
struct Pick: Codable {
    let time: Double
    let beatIndex: Int
    let isEvenBeat: Bool
    let kept: Bool
    let residualMs: Double
}
var picks: [Pick] = []
for t in preMF.tickTimings.sorted(by: { $0.beatIndex < $1.beatIndex }) {
    let absTime = slope * Double(t.beatIndex) + intercept + t.residualMs / 1000.0
    picks.append(Pick(
        time: absTime,
        beatIndex: t.beatIndex,
        isEvenBeat: t.isEvenBeat,
        kept: keptIndices.contains(t.beatIndex),
        residualMs: t.residualMs
    ))
}

// Window boundaries: at midpoints between consecutive predicted tick
// positions. We anchor at intercept and step by slope. Cover the full
// recording duration even past the last pick.
var boundaries: [Double] = []
let duration = Double(buffer.samples.count) / buffer.sampleRate
var i = 0
while true {
    let mid = slope * (Double(i) - 0.5) + intercept  // halfway before beat i
    if mid > duration { break }
    if mid >= 0 { boundaries.append(mid) }
    i += 1
}

struct Output: Codable {
    let fileName: String
    let sampleRate: Double
    let duration: Double
    let snappedRateBph: Int
    let periodMs: Double
    let rateError: Double
    let beatErrorMs: Double?
    let qualityScore: Double
    let totalPicks: Int
    let keptPicks: Int
    let envelope: EnvelopeBlock
    let picks: [Pick]
    let windowBoundaries: [Double]
}
struct EnvelopeBlock: Codable {
    let sampleRate: Double
    let samples: [Float]
}

let output = Output(
    fileName: url.lastPathComponent,
    sampleRate: buffer.sampleRate,
    duration: duration,
    snappedRateBph: postMF.snappedRate.rawValue,
    periodMs: slope * 1000.0,
    rateError: postMF.rateErrorSecondsPerDay,
    beatErrorMs: postMF.beatErrorMilliseconds,
    qualityScore: postMF.qualityScore,
    totalPicks: picks.count,
    keptPicks: picks.filter { $0.kept }.count,
    envelope: EnvelopeBlock(sampleRate: outRate, samples: envOut),
    picks: picks,
    windowBoundaries: boundaries
)

let encoder = JSONEncoder()
encoder.outputFormatting = []
let data = try encoder.encode(output)
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
print("  picks=\(picks.count) kept=\(picks.filter{ $0.kept }.count) trimmed=\(picks.filter{ !$0.kept }.count)")
print("  envelope=\(envOut.count) samples @ \(Int(outRate)) Hz")
print("  windowBoundaries=\(boundaries.count)")
