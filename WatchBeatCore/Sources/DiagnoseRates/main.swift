import Foundation
import WatchBeatCore

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("Usage: DiagnoseRates <file.wav> [<file.wav> ...]")
    exit(1)
}

let pipeline = MeasurementPipeline()

for path in args {
    let url = URL(fileURLWithPath: path)
    guard let buf = try? WAVReader.read(url: url) else {
        print("\n\(url.lastPathComponent): could not load")
        continue
    }

    print("\n================================================================")
    print("\(url.lastPathComponent)  (sr=\(Int(buf.sampleRate)), dur=\(String(format: "%.2f", Double(buf.samples.count) / buf.sampleRate))s)")
    print("================================================================")

    // Free-rate measurement (what the app would produce)
    let (freeResult, diag) = pipeline.measureWithDiagnostics(buf)
    print("FREE-RATE WINNER: \(freeResult.snappedRate.rawValue) bph  q=\(Int(freeResult.qualityScore * 100))%  rate=\(String(format: "%+.1f", freeResult.rateErrorSecondsPerDay))s/d  ticks=\(freeResult.tickCount)")

    print("\nEnvelope FFT magnitudes (sorted):")
    for (rate, mag) in diag.rateScores {
        let marker = rate == freeResult.snappedRate ? " <-- winner" : ""
        print("  \(rate.rawValue) bph  (\(String(format: "%.2f", rate.hz)) Hz)   mag=\(String(format: "%.4f", mag))\(marker)")
    }

    print("\nForced per-rate pipeline results:")
    print("  rate(bph)   quality  ticks  period(ms)  rate_err        beat_err")
    for rate in StandardBeatRate.allCases {
        let result = pipeline.measure(buf, knownRate: rate)
        let periodMs = rate.nominalPeriodSeconds * 1000.0
        let beatErrStr = result.beatErrorMilliseconds.map { String(format: "%.2f ms", $0) } ?? "--"
        let marker = rate == freeResult.snappedRate ? " *" : ""
        let qualStr = String(format: "%3d%%", Int(result.qualityScore * 100))
        let periodStr = String(format: "%.2f", periodMs)
        let rateErrStr = String(format: "%+.1f s/d", result.rateErrorSecondsPerDay)
        print("  \(rate.rawValue)      \(qualStr)    \(result.tickCount)     \(periodStr)      \(rateErrStr)     \(beatErrStr)\(marker)")
    }
}
