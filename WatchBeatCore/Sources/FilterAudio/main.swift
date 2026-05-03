import Foundation
import WatchBeatCore

// CLI: highpass-filter a WAV recording so the user can listen to what
// the pipeline sees post-filter. Useful when the raw recording is
// dominated by speech / room noise that masks any watch ticks — the
// 5 kHz HP cutoff isolates the band where ticks have most of their
// energy.
//
// Usage:
//   FilterAudio path/to/input.wav [cutoff_hz]
//
// Default cutoff is 5000 Hz (matches the pipeline's primary HP cutoff).
// Output goes next to the input as input.hp<cutoff>.wav.

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("Usage: FilterAudio <input.wav> [cutoff_hz]\n".data(using: .utf8)!)
    FileHandle.standardError.write("  Default cutoff: 5000 Hz\n".data(using: .utf8)!)
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let cutoffHz: Double = CommandLine.arguments.count >= 3
    ? (Double(CommandLine.arguments[2]) ?? 5000)
    : 5000

let inputURL = URL(fileURLWithPath: inputPath)
guard let buffer = try? WAVReader.read(url: inputURL) else {
    FileHandle.standardError.write("Could not read \(inputPath)\n".data(using: .utf8)!)
    exit(1)
}

let conditioner = SignalConditioner()
let filtered = conditioner.highpassFilter(buffer.samples,
                                          sampleRate: buffer.sampleRate,
                                          cutoff: cutoffHz)

// Compose output filename: input.hp5000.wav for cutoff=5000.
let stem = inputURL.deletingPathExtension()
let outputURL = stem.appendingPathExtension("hp\(Int(cutoffHz))").appendingPathExtension("wav")

// Write 32-bit float WAV (matches the format MeasurementCoordinator
// uses for saved recordings — keeps the format consistent across the
// project's test corpus).
let sampleRate = UInt32(buffer.sampleRate)
let numSamples = UInt32(filtered.count)
let dataSize = numSamples * 4
let fileSize = 36 + dataSize

var data = Data()
data.append(contentsOf: "RIFF".utf8)
data.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
data.append(contentsOf: "WAVE".utf8)
data.append(contentsOf: "fmt ".utf8)
data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })  // chunk size
data.append(withUnsafeBytes(of: UInt16(3).littleEndian) { Data($0) })   // IEEE float
data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // mono
data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
data.append(withUnsafeBytes(of: (sampleRate * 4).littleEndian) { Data($0) })  // byte rate
data.append(withUnsafeBytes(of: UInt16(4).littleEndian) { Data($0) })   // block align
data.append(withUnsafeBytes(of: UInt16(32).littleEndian) { Data($0) })  // bits per sample
data.append(contentsOf: "data".utf8)
data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
filtered.withUnsafeBytes { data.append(contentsOf: $0) }

do {
    try data.write(to: outputURL)
    print("Wrote \(outputURL.path)")
    print("  duration: \(String(format: "%.2f", Double(filtered.count) / buffer.sampleRate)) s")
    print("  HP cutoff: \(Int(cutoffHz)) Hz")
} catch {
    FileHandle.standardError.write("Could not write \(outputURL.path): \(error)\n".data(using: .utf8)!)
    exit(1)
}

