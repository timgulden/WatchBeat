import XCTest
@testable import WatchBeatCore

/// Integration tests per spec section 8: for each standard beat rate, generate a 30-second
/// synthetic signal with injected rate error and run the full pipeline.
final class PipelineIntegrationTests: XCTestCase {

    let generator = SyntheticTickGenerator()
    let pipeline = MeasurementPipeline()

    // MARK: - High SNR (40 dB): rate error within ±0.5 s/day, correct rate, quality > 0.8

    func testPipeline28800HighSNR() {
        assertPipeline(beatRate: .bph28800, snrDb: 40.0, injectedError: 5.0,
                       tolerance: 1.0, minQuality: 0.8)
    }

    func testPipeline21600HighSNR() {
        assertPipeline(beatRate: .bph21600, snrDb: 40.0, injectedError: 5.0,
                       tolerance: 1.0, minQuality: 0.8)
    }

    func testPipeline18000HighSNR() {
        assertPipeline(beatRate: .bph18000, snrDb: 40.0, injectedError: 5.0,
                       tolerance: 1.0, minQuality: 0.5)
    }

    func testPipeline14400HighSNR() {
        assertPipeline(beatRate: .bph14400, snrDb: 40.0, injectedError: 5.0,
                       tolerance: 2.0, minQuality: 0.5)
    }

    func testPipeline25200HighSNR() {
        assertPipeline(beatRate: .bph25200, snrDb: 40.0, injectedError: 5.0,
                       tolerance: 1.0, minQuality: 0.5)
    }

    func testPipeline36000HighSNR() {
        assertPipeline(beatRate: .bph36000, snrDb: 40.0, injectedError: 5.0,
                       tolerance: 1.0, minQuality: 0.5)
    }

    func testPipelineQuartzHighSNR() {
        // Quartz at 1 Hz has only ~30 ticks in 30s, so quality is inherently lower
        assertPipeline(beatRate: .bph3600, snrDb: 40.0, injectedError: 5.0,
                       tolerance: 2.0, minQuality: 0.1)
    }

    // MARK: - Moderate SNR (20 dB): rate error within ±2 s/day

    func testPipeline28800ModerateSNR() {
        assertPipeline(beatRate: .bph28800, snrDb: 20.0, injectedError: 5.0,
                       tolerance: 2.0, minQuality: 0.3)
    }

    // MARK: - Negative rate error

    func testPipelineNegativeRateError() {
        assertPipeline(beatRate: .bph28800, snrDb: 40.0, injectedError: -5.0,
                       tolerance: 1.0, minQuality: 0.8)
    }

    // MARK: - Full pipeline via MeasurementPipeline entry point

    func testMeasurementPipelineEntryPoint() {
        let params = SyntheticTickParameters(
            beatRate: .bph28800,
            durationSeconds: 30.0,
            sampleRate: 48000.0,
            rateErrorSecondsPerDay: 5.0,
            snrDb: 40.0
        )
        let signal = generator.generate(parameters: params)
        let result = pipeline.measure(signal.buffer)

        XCTAssertEqual(result.snappedRate, .bph28800)
        XCTAssertEqual(result.rateErrorSecondsPerDay, 5.0, accuracy: 1.0)
        XCTAssertGreaterThan(result.tickCount, 100)
        XCTAssertGreaterThan(result.qualityScore, 0.5)
    }

    // MARK: - Helper

    func assertPipeline(
        beatRate: StandardBeatRate,
        snrDb: Double,
        injectedError: Double,
        tolerance: Double,
        minQuality: Double,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let params = SyntheticTickParameters(
            beatRate: beatRate,
            durationSeconds: 30.0,
            sampleRate: 48000.0,
            rateErrorSecondsPerDay: injectedError,
            snrDb: snrDb
        )
        let signal = generator.generate(parameters: params)
        let result = pipeline.measure(signal.buffer)

        XCTAssertEqual(result.snappedRate, beatRate,
                       "\(beatRate): wrong rate \(result.snappedRate)", file: file, line: line)
        XCTAssertEqual(result.rateErrorSecondsPerDay, injectedError, accuracy: tolerance,
                       "\(beatRate): rate error \(result.rateErrorSecondsPerDay) not within ±\(tolerance) of \(injectedError)",
                       file: file, line: line)
        XCTAssertGreaterThan(result.qualityScore, minQuality,
                             "\(beatRate): quality \(result.qualityScore) < \(minQuality)",
                             file: file, line: line)
    }
}
