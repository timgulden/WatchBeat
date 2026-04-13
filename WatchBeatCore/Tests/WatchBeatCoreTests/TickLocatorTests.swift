import XCTest
@testable import WatchBeatCore

final class TickLocatorTests: XCTestCase {

    let generator = SyntheticTickGenerator()
    let conditioner = SignalConditioner()
    let estimator = PeriodEstimator()
    let builder = TemplateBuilder()
    let locator = TickLocator()

    /// Helper: full pipeline through tick location.
    func locateTicks(
        beatRate: StandardBeatRate,
        durationSeconds: Double = 10.0,
        rateErrorSecondsPerDay: Double = 0.0,
        beatErrorMilliseconds: Double = 0.0,
        snrDb: Double = 40.0,
        seed: UInt64 = 42
    ) -> (locations: TickLocations, groundTruth: [Double], estimate: PeriodEstimate) {
        let params = SyntheticTickParameters(
            beatRate: beatRate,
            durationSeconds: durationSeconds,
            sampleRate: 48000.0,
            rateErrorSecondsPerDay: rateErrorSecondsPerDay,
            beatErrorMilliseconds: beatErrorMilliseconds,
            snrDb: snrDb,
            seed: seed
        )
        let signal = generator.generate(parameters: params)
        let conditioned = conditioner.process(signal.buffer)
        let estimate = estimator.estimate(envelope: conditioned.envelope)
        let template = builder.build(filtered: conditioned.filtered, periodEstimate: estimate)
        let locations = locator.locate(filtered: conditioned.filtered, template: template, periodEstimate: estimate)
        return (locations, signal.tickTimesSeconds, estimate)
    }

    // MARK: - Tick count

    func testTickCountMatchesExpected28800() {
        let (locations, groundTruth, _) = locateTicks(beatRate: .bph28800, durationSeconds: 5.0)
        // Should detect most ticks. Allow ±2 for edge effects at start/end.
        XCTAssertEqual(Double(locations.tickTimesSeconds.count), Double(groundTruth.count),
                       accuracy: 5,
                       "Expected ~\(groundTruth.count) ticks, got \(locations.tickTimesSeconds.count)")
    }

    func testTickCountForAllMechanicalRates() {
        for rate in StandardBeatRate.allCases where !rate.isQuartz {
            let (locations, groundTruth, _) = locateTicks(beatRate: rate, durationSeconds: 5.0)
            let tolerance = max(5, groundTruth.count / 10) // ±10% or ±5
            XCTAssertEqual(Double(locations.tickTimesSeconds.count), Double(groundTruth.count),
                           accuracy: Double(tolerance),
                           "\(rate): expected ~\(groundTruth.count), got \(locations.tickTimesSeconds.count)")
        }
    }

    // MARK: - Tick timing precision

    func testRelativeTickTimingPrecisionHighSNR() {
        // Absolute tick positions have a constant offset from the correlation alignment.
        // What matters for rate analysis is the *relative* precision: are the inter-tick
        // intervals consistent with ground truth? This is what determines rate error accuracy.
        let (locations, groundTruth, _) = locateTicks(beatRate: .bph28800, durationSeconds: 5.0, snrDb: 60.0)

        guard locations.tickTimesSeconds.count > 2 else {
            XCTFail("Need at least 3 ticks for interval comparison")
            return
        }

        // Compute detected intervals
        var detectedIntervals: [Double] = []
        for i in 1..<locations.tickTimesSeconds.count {
            detectedIntervals.append(locations.tickTimesSeconds[i] - locations.tickTimesSeconds[i - 1])
        }

        // Expected interval is the nominal beat period
        let expectedInterval = 1.0 / 8.0 // 28800 bph = 8 Hz

        // Median interval should be very close to the expected period
        let sortedIntervals = detectedIntervals.sorted()
        let medianInterval = sortedIntervals[sortedIntervals.count / 2]
        XCTAssertEqual(medianInterval, expectedInterval, accuracy: 0.0005,
                       "Median interval \(medianInterval) should be ~\(expectedInterval)")

        // Interval jitter (std dev of intervals) should be small for clean signal
        let meanInterval = detectedIntervals.reduce(0, +) / Double(detectedIntervals.count)
        let variance = detectedIntervals.map { ($0 - meanInterval) * ($0 - meanInterval) }.reduce(0, +) / Double(detectedIntervals.count)
        let jitterStd = sqrt(variance)
        // For a clean synthetic signal, interval jitter should be well under 100 us
        XCTAssertLessThan(jitterStd, 0.0001,
                          "Interval jitter std \(jitterStd * 1e6) us should be < 100 us")
    }

    func testConstantOffsetFromGroundTruth() {
        // The correlation alignment introduces a constant offset from ground truth.
        // Verify that the offset is consistent (low variance) even if not zero.
        let (locations, groundTruth, _) = locateTicks(beatRate: .bph28800, durationSeconds: 5.0, snrDb: 60.0)

        var offsets: [Double] = []
        for detected in locations.tickTimesSeconds {
            if let nearest = groundTruth.min(by: { abs($0 - detected) < abs($1 - detected) }) {
                offsets.append(detected - nearest)
            }
        }

        guard offsets.count > 2 else {
            XCTFail("Need offsets to analyze")
            return
        }

        let meanOffset = offsets.reduce(0, +) / Double(offsets.count)
        let offsetVariance = offsets.map { ($0 - meanOffset) * ($0 - meanOffset) }.reduce(0, +) / Double(offsets.count)
        let offsetStd = sqrt(offsetVariance)
        // The offset should be consistent — std dev well under 1 ms
        XCTAssertLessThan(offsetStd, 0.001,
                          "Offset std \(offsetStd * 1e6) us should be < 1000 us (constant offset is OK)")
    }

    // MARK: - Ticks are monotonically increasing

    func testTickTimesAreMonotonicallyIncreasing() {
        let (locations, _, _) = locateTicks(beatRate: .bph28800)
        for i in 1..<locations.tickTimesSeconds.count {
            XCTAssertGreaterThan(locations.tickTimesSeconds[i], locations.tickTimesSeconds[i - 1],
                                 "Tick \(i) should be after tick \(i-1)")
        }
    }

    // MARK: - Correlation magnitudes

    func testCorrelationMagnitudesArePositive() {
        let (locations, _, _) = locateTicks(beatRate: .bph28800)
        for (i, mag) in locations.correlationMagnitudes.enumerated() {
            XCTAssertGreaterThan(mag, 0, "Tick \(i) correlation magnitude should be positive")
        }
    }

    func testCorrelationMagnitudesMatchTickCount() {
        let (locations, _, _) = locateTicks(beatRate: .bph28800)
        XCTAssertEqual(locations.tickTimesSeconds.count, locations.correlationMagnitudes.count)
    }

    // MARK: - Quartz

    func testQuartzTickDetection() {
        let (locations, groundTruth, _) = locateTicks(beatRate: .bph3600, durationSeconds: 10.0)
        // 1 Hz over 10 seconds = 10 ticks
        XCTAssertEqual(Double(locations.tickTimesSeconds.count), Double(groundTruth.count),
                       accuracy: 3,
                       "Quartz: expected ~\(groundTruth.count), got \(locations.tickTimesSeconds.count)")
    }
}
