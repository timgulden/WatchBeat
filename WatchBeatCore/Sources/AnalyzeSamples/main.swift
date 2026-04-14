import Foundation
import Accelerate
import WatchBeatCore

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let files = try FileManager.default.contentsOfDirectory(atPath: dir)
    .filter { $0.hasSuffix(".wav") }
    .sorted()

guard !files.isEmpty else { print("No WAV files"); exit(1) }

print("=== Pipeline with w20 on \(files.count) samples ===\n")

func analyze(_ filename: String) {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(filename)
    guard let buffer = try? WAVReader.read(url: url) else { return }
    let pipeline = MeasurementPipeline()
    let result = pipeline.measure(buffer)
    let short = String(filename.dropFirst(10).dropLast(4))
    let be = result.beatErrorMilliseconds.map { String(format: "%.1f", $0) } ?? "-"
    print("\(short)  rate=\(result.snappedRate.rawValue)  t=\(result.tickCount)  " +
          "q=\(Int(result.qualityScore*100))%  err=\(Int(result.rateErrorSecondsPerDay))  be=\(be)ms")
}

for f in files { analyze(f) }
print()
