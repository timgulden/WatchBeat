import XCTest
@testable import WatchBeatCore

final class PeriodEstimatorTests: XCTestCase {

    let generator = SyntheticTickGenerator()
    let conditioner = SignalConditioner()
    let estimator = PeriodEstimator()

    /// Helper: generate a synthetic signal, condition it, and estimate the period.
    func estimateRate(
        beatRate: StandardBeatRate,
        rateErrorSecondsPerDay: Double = 0.0,
        durationSeconds: Double = 30.0,
        snrDb: Double = 40.0,
        seed: UInt64 = 42
    ) -> PeriodEstimate {
        let params = SyntheticTickParameters(
            beatRate: beatRate,
            durationSeconds: durationSeconds,
            sampleRate: 48000.0,
            rateErrorSecondsPerDay: rateErrorSecondsPerDay,
            snrDb: snrDb,
            seed: seed
        )
        let signal = generator.generate(parameters: params)
        let conditioned = conditioner.process(signal.buffer)
        return estimator.estimate(envelope: conditioned.envelope)
    }

    // MARK: - Correct rate detection at high SNR

    func testDetects28800bphHighSNR() {
        let result = estimateRate(beatRate: .bph28800, snrDb: 40.0)
        XCTAssertEqual(result.snappedRate, .bph28800)
        XCTAssertGreaterThan(result.confidence, 0.5)
        XCTAssertEqual(result.measuredHz, 8.0, accuracy: 0.1)
    }

    func testDetectsAllStandardRatesHighSNR() {
        for rate in StandardBeatRate.allCases {
            let result = estimateRate(beatRate: rate, snrDb: 40.0)
            XCTAssertEqual(result.snappedRate, rate,
                           "Expected \(rate) but got \(result.snappedRate) (measured \(result.measuredHz) Hz)")
            XCTAssertGreaterThan(result.confidence, 0.3,
                                 "Low confidence \(result.confidence) for \(rate)")
        }
    }

    // MARK: - Frequency precision

    func testMeasuredHzAccuracyAt28800() {
        let result = estimateRate(beatRate: .bph28800, snrDb: 40.0)
        XCTAssertEqual(result.measuredHz, 8.0, accuracy: 0.05)
    }

    func testSlightlyFastStillSnapsCorrectly() {
        // +5 s/day shifts frequency by ~0.0005 Hz — far below FFT resolution.
        // The period estimator's job is to identify the correct standard rate;
        // precise rate error comes from the tick localization + regression stages.
        let result = estimateRate(beatRate: .bph28800, rateErrorSecondsPerDay: 5.0, snrDb: 40.0)
        XCTAssertEqual(result.snappedRate, .bph28800)
        // Measured Hz should still be close to 8.0
        XCTAssertEqual(result.measuredHz, 8.0, accuracy: 0.1)
    }

    func testSlightlySlowStillSnapsCorrectly() {
        let result = estimateRate(beatRate: .bph28800, rateErrorSecondsPerDay: -5.0, snrDb: 40.0)
        XCTAssertEqual(result.snappedRate, .bph28800)
        XCTAssertEqual(result.measuredHz, 8.0, accuracy: 0.1)
    }

    // MARK: - SNR robustness

    func testModerateSNR() {
        let result = estimateRate(beatRate: .bph28800, snrDb: 20.0)
        XCTAssertEqual(result.snappedRate, .bph28800)
    }

    func testLowSNRReducesConfidence() {
        let highSNR = estimateRate(beatRate: .bph28800, snrDb: 40.0)
        let lowSNR = estimateRate(beatRate: .bph28800, snrDb: 3.0)
        XCTAssertLessThan(lowSNR.confidence, highSNR.confidence,
                          "Low SNR confidence (\(lowSNR.confidence)) should be less than high SNR (\(highSNR.confidence))")
    }

    // MARK: - Pure noise

    func testPureNoiseGivesLowConfidence() {
        // Create a buffer of pure noise with no periodic structure
        let sampleRate = 1000.0
        let duration = 30.0
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        // Incommensurate sinusoids to avoid any accidental periodicity
        for i in 0..<count {
            let t = Double(i) / sampleRate
            samples[i] = Float(sin(2.0 * .pi * 3.17 * t) + sin(2.0 * .pi * 7.83 * t) + sin(2.0 * .pi * 1.41 * t))
        }
        let envelope = AudioBuffer(samples: samples, sampleRate: sampleRate)
        let result = estimator.estimate(envelope: envelope)
        // With no clear single dominant frequency, confidence should be moderate at best
        // (the sinusoids will create peaks, but HPS should spread the energy)
        XCTAssertLessThan(result.confidence, 0.8,
                          "Noise-like signal should not produce very high confidence, got \(result.confidence)")
    }

    // MARK: - Duration sensitivity

    func testShorterCaptureStillWorks() {
        let result = estimateRate(beatRate: .bph28800, durationSeconds: 10.0, snrDb: 40.0)
        XCTAssertEqual(result.snappedRate, .bph28800)
    }

    // MARK: - Each mechanical rate individually

    func testDetects14400bph() {
        let result = estimateRate(beatRate: .bph14400)
        XCTAssertEqual(result.snappedRate, .bph14400)
        XCTAssertEqual(result.measuredHz, 4.0, accuracy: 0.1)
    }

    func testDetects18000bph() {
        let result = estimateRate(beatRate: .bph18000)
        XCTAssertEqual(result.snappedRate, .bph18000)
        XCTAssertEqual(result.measuredHz, 5.0, accuracy: 0.1)
    }

    func testDetects21600bph() {
        let result = estimateRate(beatRate: .bph21600)
        XCTAssertEqual(result.snappedRate, .bph21600)
        XCTAssertEqual(result.measuredHz, 6.0, accuracy: 0.1)
    }

    func testDetects36000bph() {
        let result = estimateRate(beatRate: .bph36000)
        XCTAssertEqual(result.snappedRate, .bph36000)
        XCTAssertEqual(result.measuredHz, 10.0, accuracy: 0.1)
    }
}
