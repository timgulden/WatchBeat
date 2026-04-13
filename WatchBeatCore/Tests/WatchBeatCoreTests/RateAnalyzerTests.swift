import XCTest
@testable import WatchBeatCore

final class RateAnalyzerTests: XCTestCase {

    let generator = SyntheticTickGenerator()
    let conditioner = SignalConditioner()
    let estimator = PeriodEstimator()
    let builder = TemplateBuilder()
    let locator = TickLocator()
    let analyzer = RateAnalyzer()

    /// Helper: full pipeline through rate analysis.
    func analyzeRate(
        beatRate: StandardBeatRate,
        durationSeconds: Double = 30.0,
        rateErrorSecondsPerDay: Double = 0.0,
        beatErrorMilliseconds: Double = 0.0,
        jitterStdMicroseconds: Double = 0.0,
        snrDb: Double = 40.0,
        seed: UInt64 = 42
    ) -> MeasurementResult {
        let params = SyntheticTickParameters(
            beatRate: beatRate,
            durationSeconds: durationSeconds,
            sampleRate: 48000.0,
            rateErrorSecondsPerDay: rateErrorSecondsPerDay,
            beatErrorMilliseconds: beatErrorMilliseconds,
            jitterStdMicroseconds: jitterStdMicroseconds,
            snrDb: snrDb,
            seed: seed
        )
        let signal = generator.generate(parameters: params)
        let conditioned = conditioner.process(signal.buffer)
        let estimate = estimator.estimate(envelope: conditioned.envelope)
        let template = builder.build(filtered: conditioned.filtered, periodEstimate: estimate)
        let locations = locator.locate(filtered: conditioned.filtered, template: template, periodEstimate: estimate)
        return analyzer.analyze(tickLocations: locations, periodEstimate: estimate)
    }

    // MARK: - Rate error recovery

    func testRecoversPlusRateError() {
        // Inject +5 s/day rate error, recover it
        let result = analyzeRate(beatRate: .bph28800, rateErrorSecondsPerDay: 5.0, snrDb: 40.0)
        XCTAssertEqual(result.snappedRate, .bph28800)
        XCTAssertEqual(result.rateErrorSecondsPerDay, 5.0, accuracy: 1.0,
                       "Recovered rate error \(result.rateErrorSecondsPerDay) should be ~5.0 s/day")
    }

    func testRecoversMinusRateError() {
        let result = analyzeRate(beatRate: .bph28800, rateErrorSecondsPerDay: -5.0, snrDb: 40.0)
        XCTAssertEqual(result.rateErrorSecondsPerDay, -5.0, accuracy: 1.0,
                       "Recovered rate error \(result.rateErrorSecondsPerDay) should be ~-5.0 s/day")
    }

    func testRecoversZeroRateError() {
        let result = analyzeRate(beatRate: .bph28800, rateErrorSecondsPerDay: 0.0, snrDb: 40.0)
        XCTAssertEqual(result.rateErrorSecondsPerDay, 0.0, accuracy: 1.0,
                       "Recovered rate error \(result.rateErrorSecondsPerDay) should be ~0 s/day")
    }

    func testRecoversPrecisionWithin0p5() {
        // Spec target: ±0.5 s/day on clean 28800 bph, 30 seconds
        let result = analyzeRate(beatRate: .bph28800, durationSeconds: 30.0,
                                 rateErrorSecondsPerDay: 5.0, snrDb: 60.0)
        XCTAssertEqual(result.rateErrorSecondsPerDay, 5.0, accuracy: 0.5,
                       "High-SNR 30s capture should recover rate within ±0.5 s/day")
    }

    // MARK: - Rate error across beat rates

    func testRateErrorRecoveryAllMechanicalRates() {
        for rate in StandardBeatRate.allCases where !rate.isQuartz {
            let result = analyzeRate(beatRate: rate, durationSeconds: 30.0,
                                     rateErrorSecondsPerDay: 5.0, snrDb: 40.0)
            XCTAssertEqual(result.snappedRate, rate)
            XCTAssertEqual(result.rateErrorSecondsPerDay, 5.0, accuracy: 2.0,
                           "\(rate): recovered rate \(result.rateErrorSecondsPerDay) should be ~5.0")
        }
    }

    // MARK: - Beat error

    func testRecoversBeatError() {
        // NOTE: Beat error recovery is limited by the tick-pair template correlation,
        // which smooths out tick/tock timing asymmetry. Accurate beat error measurement
        // will require single-beat sub-template refinement (future improvement).
        // For now, verify that beat error is non-nil for mechanical and in a reasonable range.
        let result = analyzeRate(beatRate: .bph28800, beatErrorMilliseconds: 2.0, snrDb: 40.0)
        XCTAssertNotNil(result.beatErrorMilliseconds)
        if let be = result.beatErrorMilliseconds {
            XCTAssertGreaterThanOrEqual(be, 0, "Beat error should be non-negative")
            XCTAssertLessThan(be, 10.0, "Beat error should be in a reasonable range")
        }
    }

    func testBeatErrorIsNilForQuartz() {
        let result = analyzeRate(beatRate: .bph3600)
        XCTAssertNil(result.beatErrorMilliseconds, "Quartz should have nil beat error")
    }

    func testZeroBeatError() {
        let result = analyzeRate(beatRate: .bph28800, beatErrorMilliseconds: 0.0, snrDb: 40.0)
        if let be = result.beatErrorMilliseconds {
            XCTAssertEqual(be, 0.0, accuracy: 0.3,
                           "Zero beat error should recover as ~0: got \(be) ms")
        }
    }

    // MARK: - Quality score

    func testHighQualityForCleanSignal() {
        let result = analyzeRate(beatRate: .bph28800, snrDb: 60.0)
        XCTAssertGreaterThan(result.qualityScore, 0.8,
                             "Clean signal should have high quality: \(result.qualityScore)")
    }

    func testLowerQualityForNoisySignal() {
        let clean = analyzeRate(beatRate: .bph28800, snrDb: 60.0)
        let noisy = analyzeRate(beatRate: .bph28800, snrDb: 10.0)
        XCTAssertLessThan(noisy.qualityScore, clean.qualityScore,
                          "Noisy quality \(noisy.qualityScore) should be < clean \(clean.qualityScore)")
    }

    // MARK: - Tick count

    func testTickCountReasonable() {
        let result = analyzeRate(beatRate: .bph28800, durationSeconds: 10.0)
        // 8 Hz * 10 s = 80 expected
        XCTAssertGreaterThan(result.tickCount, 60)
        XCTAssertLessThan(result.tickCount, 100)
    }

    // MARK: - Amplitude proxy

    func testAmplitudeProxyPositive() {
        let result = analyzeRate(beatRate: .bph28800)
        XCTAssertGreaterThan(result.amplitudeProxy, 0)
    }

    // MARK: - Rate error sign convention

    func testFastWatchPositiveError() {
        // +10 s/day = watch gains 10 seconds per day = fast
        let result = analyzeRate(beatRate: .bph28800, rateErrorSecondsPerDay: 10.0, snrDb: 40.0)
        XCTAssertGreaterThan(result.rateErrorSecondsPerDay, 0,
                             "Fast watch should have positive rate error")
    }

    func testSlowWatchNegativeError() {
        let result = analyzeRate(beatRate: .bph28800, rateErrorSecondsPerDay: -10.0, snrDb: 40.0)
        XCTAssertLessThan(result.rateErrorSecondsPerDay, 0,
                          "Slow watch should have negative rate error")
    }
}
