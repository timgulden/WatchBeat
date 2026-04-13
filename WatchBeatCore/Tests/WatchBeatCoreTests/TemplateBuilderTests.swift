import XCTest
@testable import WatchBeatCore

final class TemplateBuilderTests: XCTestCase {

    let generator = SyntheticTickGenerator()
    let conditioner = SignalConditioner()
    let estimator = PeriodEstimator()
    let builder = TemplateBuilder()

    /// Helper: generate signal, condition, estimate period, build template.
    func buildTemplate(
        beatRate: StandardBeatRate,
        durationSeconds: Double = 10.0,
        snrDb: Double = 40.0
    ) -> (template: TickTemplate, periodEstimate: PeriodEstimate) {
        let params = SyntheticTickParameters(
            beatRate: beatRate,
            durationSeconds: durationSeconds,
            sampleRate: 48000.0,
            snrDb: snrDb
        )
        let signal = generator.generate(parameters: params)
        let conditioned = conditioner.process(signal.buffer)
        let estimate = estimator.estimate(envelope: conditioned.envelope)
        let template = builder.build(filtered: conditioned.filtered, periodEstimate: estimate)
        return (template, estimate)
    }

    // MARK: - Template length

    func testTemplateLengthMatchesTwoBeatsForMechanical() {
        let (template, estimate) = buildTemplate(beatRate: .bph28800)
        let expectedLength = Int(round(2.0 * 48000.0 / estimate.measuredHz))
        // Allow ±1 sample for rounding
        XCTAssertEqual(template.samples.count, expectedLength, accuracy: 1,
                       "Template should span 2 beats: expected \(expectedLength), got \(template.samples.count)")
        XCTAssertEqual(template.spansBeats, 2)
    }

    func testTemplateLengthMatchesOneBeatForQuartz() {
        let (template, estimate) = buildTemplate(beatRate: .bph3600)
        let expectedLength = Int(round(48000.0 / estimate.measuredHz))
        XCTAssertEqual(template.samples.count, expectedLength, accuracy: 1,
                       "Quartz template should span 1 beat")
        XCTAssertEqual(template.spansBeats, 1)
    }

    func testTemplateLengthAllRates() {
        for rate in StandardBeatRate.allCases {
            let (template, estimate) = buildTemplate(beatRate: rate)
            let beatsPerTemplate = rate.isQuartz ? 1 : 2
            let expectedLength = Int(round(Double(beatsPerTemplate) * 48000.0 / estimate.measuredHz))
            XCTAssertEqual(template.samples.count, expectedLength, accuracy: 1,
                           "\(rate): template length \(template.samples.count) != expected \(expectedLength)")
        }
    }

    // MARK: - Unit energy normalization

    func testTemplateHasUnitEnergy() {
        let (template, _) = buildTemplate(beatRate: .bph28800)
        let energy = template.samples.map { $0 * $0 }.reduce(0, +)
        XCTAssertEqual(energy, 1.0, accuracy: 1e-4, "Template should be normalized to unit energy")
    }

    func testTemplateHasUnitEnergyAllRates() {
        for rate in StandardBeatRate.allCases {
            let (template, _) = buildTemplate(beatRate: rate)
            let energy = template.samples.map { $0 * $0 }.reduce(0, +)
            XCTAssertEqual(energy, 1.0, accuracy: 1e-4, "\(rate): template energy \(energy) != 1.0")
        }
    }

    // MARK: - Template correlates with tick shape

    func testTemplateCorrelatesWithSyntheticTick() {
        // Build a template from a clean 28800 bph signal
        let (template, _) = buildTemplate(beatRate: .bph28800, snrDb: 60.0)

        // Generate a single synthetic tick for comparison
        // The mechanical tick is a 5 kHz decaying burst, ~4 ms = ~192 samples
        let tickDuration = 0.004
        let tickSamples = Int(tickDuration * 48000.0)
        var singleTick = [Float](repeating: 0, count: tickSamples)
        for i in 0..<tickSamples {
            let t = Double(i) / 48000.0
            singleTick[i] = Float(exp(-1000.0 * t) * sin(2.0 * .pi * 5000.0 * t))
        }

        // Cross-correlate the single tick with the template — should find a strong peak
        // The template has the tick waveform averaged across many folds, so
        // it should resemble the original tick shape
        let templateSamples = template.samples
        var maxCorr: Float = 0
        for offset in 0..<(templateSamples.count - tickSamples) {
            var corr: Float = 0
            for i in 0..<tickSamples {
                corr += templateSamples[offset + i] * singleTick[i]
            }
            maxCorr = max(maxCorr, abs(corr))
        }
        XCTAssertGreaterThan(maxCorr, 0.01,
                             "Template should correlate with synthetic tick shape")
    }

    // MARK: - Robustness

    func testTemplateFromNoisySignal() {
        // Even at moderate SNR, the template should be valid (non-zero, unit energy)
        let (template, _) = buildTemplate(beatRate: .bph28800, snrDb: 15.0)
        let energy = template.samples.map { $0 * $0 }.reduce(0, +)
        XCTAssertEqual(energy, 1.0, accuracy: 1e-4, "Noisy template should still have unit energy")
        XCTAssertGreaterThan(template.samples.count, 0)
    }

    func testTemplateFromShortCapture() {
        // 3-second capture — fewer folds but should still produce a valid template
        let (template, _) = buildTemplate(beatRate: .bph28800, durationSeconds: 3.0)
        let energy = template.samples.map { $0 * $0 }.reduce(0, +)
        XCTAssertEqual(energy, 1.0, accuracy: 1e-4)
        XCTAssertEqual(template.spansBeats, 2)
    }

    func testTemplateSampleRateMatchesInput() {
        let (template, _) = buildTemplate(beatRate: .bph28800)
        XCTAssertEqual(template.sampleRate, 48000.0)
    }
}

// Helper for integer accuracy comparison
private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(abs(a - b) <= accuracy, "\(message) — \(a) != \(b) (accuracy: \(accuracy))", file: file, line: line)
}
