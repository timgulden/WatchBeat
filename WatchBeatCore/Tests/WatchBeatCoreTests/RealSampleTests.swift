import XCTest
@testable import WatchBeatCore

/// Tests that run the pipeline on real recorded samples.
/// Use the AnalyzeSamples executable for batch analysis.
final class RealSampleTests: XCTestCase {

    let pipeline = MeasurementPipeline()
    let samplesDir = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SoundSamples")

    func testSingleSample() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: samplesDir.path) else {
            print("No SoundSamples directory — skipping")
            return
        }
        let files = try fm.contentsOfDirectory(atPath: samplesDir.path)
            .filter { $0.hasSuffix(".wav") }
            .sorted()
        guard let file = files.last else { return }

        let url = samplesDir.appendingPathComponent(file)
        let buffer = try WAVReader.read(url: url)
        let result = pipeline.measure(buffer)

        print("Sample: \(file)")
        print("Rate: \(result.snappedRate.rawValue) bph, Ticks: \(result.tickCount), " +
              "Quality: \(Int(result.qualityScore * 100))%, " +
              "Error: \(String(format: "%+.1f", result.rateErrorSecondsPerDay)) s/day")

        // Basic sanity
        XCTAssertGreaterThan(result.tickCount, 0)
    }
}
