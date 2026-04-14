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

    func testSlowRateNoBeatErrorAsymmetry() {
        // Verify beat error asymmetry works correctly for a slow mechanical rate
        let params = SyntheticTickParameters(
            beatRate: .bph19800,
            durationSeconds: 5.0,
            rateErrorSecondsPerDay: 0.0,
            beatErrorMilliseconds: 2.0,
            jitterStdMicroseconds: 0.0,
            snrDb: 100.0
        )
        let signal = generator.generate(parameters: params)
        let nominalPeriod = 1.0 / 5.5 // 19800 bph = 5.5 beats/sec
        let shift = 2.0 / 1000.0 / 2.0

        for i in 0..<signal.tickTimesSeconds.count {
            let idealTime = Double(i) * nominalPeriod
            let expectedShift = (i % 2 == 0) ? shift : -shift
            XCTAssertEqual(signal.tickTimesSeconds[i], idealTime + expectedShift, accuracy: 1e-12,
                           "Tick \(i) beat error offset wrong")
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
            beatRate: .bph19800,
            durationSeconds: 3.0,
            snrDb: 100.0
        )
        let signal = generator.generate(parameters: params)

        // Check a region far from any tick (midway between two ticks for 19800 bph = 5.5 Hz, period ~0.182s)
        // Pick t=0.091s which is halfway between tick at 0s and tick at 0.182s
        let midSample = Int(0.091 * params.sampleRate)
        let window = 50
        let quietEnergy = signal.buffer.samples[(midSample - window)..<(midSample + window)]
            .map { $0 * $0 }
            .reduce(0, +)
        XCTAssertEqual(quietEnergy, 0.0, accuracy: 1e-10, "Should be silent between ticks")
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

    func testLowBeatRateTickShape() {
        let params = SyntheticTickParameters(
            beatRate: .bph19800,
            durationSeconds: 3.0,
            snrDb: 100.0
        )
        let signal = generator.generate(parameters: params)
        // 19800 bph = 5.5 beats/sec, 3 seconds -> 17 ticks (0, 0.182, ..., 2.909)
        XCTAssertEqual(signal.tickTimesSeconds.count, 17)
        XCTAssertEqual(signal.buffer.samples.count, Int(3.0 * 48000.0))
    }
}

// Helper to allow ±1 tolerance on integer comparisons
private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(abs(a - b) <= accuracy, "\(message) — \(a) != \(b) (accuracy: \(accuracy))", file: file, line: line)
}
