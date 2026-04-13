import XCTest
@testable import WatchBeatCore

final class SyntheticGeneratorTests: XCTestCase {

    let generator = SyntheticTickGenerator()

    // MARK: - Basic signal properties

    func testOutputLengthMatchesDuration() {
        let params = SyntheticTickParameters(beatRate: .bph28800, durationSeconds: 10.0)
        let signal = generator.generate(parameters: params)
        XCTAssertEqual(signal.buffer.samples.count, Int(10.0 * 48000.0))
        XCTAssertEqual(signal.buffer.sampleRate, 48000.0)
    }

    func testTickCountMatchesExpected() {
        // 28800 bph = 8 Hz, 10 seconds -> 80 ticks
        let params = SyntheticTickParameters(beatRate: .bph28800, durationSeconds: 10.0)
        let signal = generator.generate(parameters: params)
        XCTAssertEqual(signal.tickTimesSeconds.count, 80)
    }

    func testTickCountForAllBeatRates() {
        for rate in StandardBeatRate.allCases {
            let params = SyntheticTickParameters(beatRate: rate, durationSeconds: 10.0)
            let signal = generator.generate(parameters: params)
            let expectedCount = Int(10.0 * rate.hz)
            // Allow ±1 for edge rounding
            XCTAssertEqual(signal.tickTimesSeconds.count, expectedCount,
                           accuracy: 1, "\(rate) expected ~\(expectedCount) ticks, got \(signal.tickTimesSeconds.count)")
        }
    }

    // MARK: - Tick timing accuracy

    func testCleanSignalTickSpacing() {
        // No jitter, no rate error, no beat error -> perfectly regular ticks
        let params = SyntheticTickParameters(
            beatRate: .bph28800,
            durationSeconds: 5.0,
            rateErrorSecondsPerDay: 0.0,
            beatErrorMilliseconds: 0.0,
            jitterStdMicroseconds: 0.0,
            snrDb: 100.0
        )
        let signal = generator.generate(parameters: params)
        let expectedPeriod = 1.0 / 8.0 // 0.125 s

        for i in 1..<signal.tickTimesSeconds.count {
            let interval = signal.tickTimesSeconds[i] - signal.tickTimesSeconds[i - 1]
            XCTAssertEqual(interval, expectedPeriod, accuracy: 1e-12,
                           "Tick \(i) interval \(interval) != \(expectedPeriod)")
        }
    }

    func testRateErrorAffectsPeriod() {
        // +10 s/day means watch runs fast -> shorter true period
        let params = SyntheticTickParameters(
            beatRate: .bph28800,
            durationSeconds: 10.0,
            rateErrorSecondsPerDay: 10.0,
            beatErrorMilliseconds: 0.0,
            jitterStdMicroseconds: 0.0
        )
        let signal = generator.generate(parameters: params)
        let nominalPeriod = StandardBeatRate.bph28800.nominalPeriodSeconds
        let expectedPeriod = nominalPeriod * (1.0 - 10.0 / 86400.0)

        // Check average period over all ticks
        let n = signal.tickTimesSeconds.count
        let totalTime = signal.tickTimesSeconds[n - 1] - signal.tickTimesSeconds[0]
        let measuredPeriod = totalTime / Double(n - 1)
        XCTAssertEqual(measuredPeriod, expectedPeriod, accuracy: 1e-12)
    }

    func testNegativeRateErrorSlowerPeriod() {
        // -5 s/day means watch runs slow -> longer true period
        let params = SyntheticTickParameters(
            beatRate: .bph28800,
            durationSeconds: 10.0,
            rateErrorSecondsPerDay: -5.0,
            beatErrorMilliseconds: 0.0,
            jitterStdMicroseconds: 0.0
        )
        let signal = generator.generate(parameters: params)
        let nominalPeriod = StandardBeatRate.bph28800.nominalPeriodSeconds
        let expectedPeriod = nominalPeriod * (1.0 - (-5.0) / 86400.0)

        let n = signal.tickTimesSeconds.count
        let measuredPeriod = (signal.tickTimesSeconds[n - 1] - signal.tickTimesSeconds[0]) / Double(n - 1)
        XCTAssertEqual(measuredPeriod, expectedPeriod, accuracy: 1e-12)
    }

    // MARK: - Beat error

    func testBeatErrorCreatesTickTockAsymmetry() {
        let beatErrorMs = 2.0
        let params = SyntheticTickParameters(
            beatRate: .bph28800,
            durationSeconds: 5.0,
            rateErrorSecondsPerDay: 0.0,
            beatErrorMilliseconds: beatErrorMs,
            jitterStdMicroseconds: 0.0,
            snrDb: 100.0
        )
        let signal = generator.generate(parameters: params)
        let nominalPeriod = 1.0 / 8.0
        let shift = beatErrorMs / 1000.0 / 2.0

        // Even ticks should be shifted +shift, odd ticks -shift from ideal
        for i in 0..<signal.tickTimesSeconds.count {
            let idealTime = Double(i) * nominalPeriod
            let expectedShift = (i % 2 == 0) ? shift : -shift
            XCTAssertEqual(signal.tickTimesSeconds[i], idealTime + expectedShift, accuracy: 1e-12,
                           "Tick \(i) beat error offset wrong")
        }
    }

    func testQuartzNoBeatError() {
        // Even if beat error param is set, quartz ticks should be regular
        let params = SyntheticTickParameters(
            beatRate: .bph3600,
            durationSeconds: 5.0,
            rateErrorSecondsPerDay: 0.0,
            beatErrorMilliseconds: 2.0,
            jitterStdMicroseconds: 0.0,
            snrDb: 100.0
        )
        let signal = generator.generate(parameters: params)
        let expectedPeriod = 1.0

        for i in 1..<signal.tickTimesSeconds.count {
            let interval = signal.tickTimesSeconds[i] - signal.tickTimesSeconds[i - 1]
            XCTAssertEqual(interval, expectedPeriod, accuracy: 1e-12,
                           "Quartz tick \(i) should have no beat error asymmetry")
        }
    }

    // MARK: - Jitter

    func testJitterAddsVariation() {
        let params = SyntheticTickParameters(
            beatRate: .bph28800,
            durationSeconds: 10.0,
            rateErrorSecondsPerDay: 0.0,
            beatErrorMilliseconds: 0.0,
            jitterStdMicroseconds: 50.0,
            snrDb: 100.0
        )
        let signal = generator.generate(parameters: params)
        let expectedPeriod = 1.0 / 8.0

        // Compute intervals and check they have nonzero variance
        var intervals: [Double] = []
        for i in 1..<signal.tickTimesSeconds.count {
            intervals.append(signal.tickTimesSeconds[i] - signal.tickTimesSeconds[i - 1])
        }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
        let stdDev = sqrt(variance)

        // Jitter std is 50 us; interval std should be sqrt(2) * 50 us ≈ 70.7 us
        // (since each interval is the difference of two jittered times)
        let expectedIntervalStd = sqrt(2.0) * 50.0 / 1_000_000.0
        XCTAssertEqual(stdDev, expectedIntervalStd, accuracy: expectedIntervalStd * 0.3,
                       "Interval jitter std \(stdDev * 1e6) us, expected ~\(expectedIntervalStd * 1e6) us")
        XCTAssertEqual(mean, expectedPeriod, accuracy: 1e-4)
    }

    // MARK: - Signal content

    func testSignalHasEnergyAtTickLocations() {
        let params = SyntheticTickParameters(
            beatRate: .bph28800,
            durationSeconds: 2.0,
            snrDb: 100.0
        )
        let signal = generator.generate(parameters: params)
        let sr = params.sampleRate

        // Check that there's nonzero energy near each tick time
        for tickTime in signal.tickTimesSeconds {
            let centerSample = Int(tickTime * sr)
            if centerSample < 0 || centerSample >= signal.buffer.samples.count { continue }
            let windowStart = max(0, centerSample - 100)
            let windowEnd = min(signal.buffer.samples.count, centerSample + 100)
            let windowEnergy = signal.buffer.samples[windowStart..<windowEnd]
                .map { $0 * $0 }
                .reduce(0, +)
            XCTAssertGreaterThan(windowEnergy, 0, "No energy near tick at \(tickTime) s")
        }
    }

    func testSignalIsQuietBetweenTicks() {
        // With high SNR and low beat rate, there should be silence between ticks
        let params = SyntheticTickParameters(
            beatRate: .bph3600,
            durationSeconds: 3.0,
            snrDb: 100.0,
            tickShape: .syntheticQuartz
        )
        let signal = generator.generate(parameters: params)

        // Check a region far from any tick (e.g., at t=0.5 s, between tick 0 at 0s and tick 1 at 1s)
        let midSample = Int(0.5 * params.sampleRate)
        let window = 100
        let quietEnergy = signal.buffer.samples[(midSample - window)..<(midSample + window)]
            .map { $0 * $0 }
            .reduce(0, +)
        XCTAssertEqual(quietEnergy, 0.0, accuracy: 1e-20, "Should be silent between quartz ticks")
    }

    // MARK: - Noise

    func testNoiseAddsEnergy() {
        let cleanParams = SyntheticTickParameters(
            beatRate: .bph28800, durationSeconds: 1.0, snrDb: 100.0, seed: 1)
        let noisyParams = SyntheticTickParameters(
            beatRate: .bph28800, durationSeconds: 1.0, snrDb: 10.0, seed: 1)

        let clean = generator.generate(parameters: cleanParams)
        let noisy = generator.generate(parameters: noisyParams)

        let cleanEnergy = clean.buffer.samples.map { $0 * $0 }.reduce(0, +)
        let noisyEnergy = noisy.buffer.samples.map { $0 * $0 }.reduce(0, +)
        XCTAssertGreaterThan(noisyEnergy, cleanEnergy, "Noisy signal should have more total energy")
    }

    // MARK: - Reproducibility

    func testDeterministicWithSameSeed() {
        let params = SyntheticTickParameters(
            beatRate: .bph28800,
            durationSeconds: 2.0,
            jitterStdMicroseconds: 50.0,
            snrDb: 20.0,
            seed: 123
        )
        let signal1 = generator.generate(parameters: params)
        let signal2 = generator.generate(parameters: params)

        XCTAssertEqual(signal1.tickTimesSeconds, signal2.tickTimesSeconds)
        XCTAssertEqual(signal1.buffer.samples, signal2.buffer.samples)
    }

    func testDifferentSeedsDifferentOutput() {
        let params1 = SyntheticTickParameters(
            beatRate: .bph28800, durationSeconds: 2.0,
            jitterStdMicroseconds: 50.0, snrDb: 20.0, seed: 1)
        let params2 = SyntheticTickParameters(
            beatRate: .bph28800, durationSeconds: 2.0,
            jitterStdMicroseconds: 50.0, snrDb: 20.0, seed: 2)

        let signal1 = generator.generate(parameters: params1)
        let signal2 = generator.generate(parameters: params2)

        XCTAssertNotEqual(signal1.tickTimesSeconds, signal2.tickTimesSeconds)
    }

    // MARK: - Quartz tick shape

    func testQuartzTickShape() {
        let params = SyntheticTickParameters(
            beatRate: .bph3600,
            durationSeconds: 3.0,
            snrDb: 100.0,
            tickShape: .syntheticQuartz
        )
        let signal = generator.generate(parameters: params)
        // Should have 3 ticks (at 0, 1, 2 seconds)
        XCTAssertEqual(signal.tickTimesSeconds.count, 3)
        XCTAssertEqual(signal.buffer.samples.count, Int(3.0 * 48000.0))
    }
}

// Helper to allow ±1 tolerance on integer comparisons
private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(abs(a - b) <= accuracy, "\(message) — \(a) != \(b) (accuracy: \(accuracy))", file: file, line: line)
}
