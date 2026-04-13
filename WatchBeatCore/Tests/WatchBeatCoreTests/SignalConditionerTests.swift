import XCTest
@testable import WatchBeatCore

final class SignalConditionerTests: XCTestCase {

    let conditioner = SignalConditioner()
    let sampleRate = 48000.0

    // MARK: - Helper: generate a pure tone

    func makeTone(frequency: Double, duration: Double, sampleRate: Double, amplitude: Float = 1.0) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { i in
            amplitude * Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate))
        }
    }

    // MARK: - Bandpass filter tests

    func testBandpassRejects100Hz() {
        // A 100 Hz tone is well below the 1 kHz highpass cutoff — should be strongly attenuated
        let tone = makeTone(frequency: 100, duration: 0.5, sampleRate: sampleRate)
        let filtered = conditioner.bandpassFilter(tone, sampleRate: sampleRate, lowCutoff: 1000, highCutoff: 10000)

        let inputEnergy = tone.map { $0 * $0 }.reduce(0, +)
        let outputEnergy = filtered.map { $0 * $0 }.reduce(0, +)
        let attenuation = outputEnergy / inputEnergy

        // 4th-order Butterworth at 100 Hz vs 1 kHz cutoff: expect massive rejection
        XCTAssertLessThan(attenuation, 0.001, "100 Hz should be rejected by bandpass, attenuation=\(attenuation)")
    }

    func testBandpassPasses5kHz() {
        // A 5 kHz tone is in the middle of the passband — should pass through mostly intact
        let tone = makeTone(frequency: 5000, duration: 0.5, sampleRate: sampleRate)
        let filtered = conditioner.bandpassFilter(tone, sampleRate: sampleRate, lowCutoff: 1000, highCutoff: 10000)

        let inputEnergy = tone.map { $0 * $0 }.reduce(0, +)
        let outputEnergy = filtered.map { $0 * $0 }.reduce(0, +)
        let passthrough = outputEnergy / inputEnergy

        // Should retain most energy (allow for some filter transient at start)
        XCTAssertGreaterThan(passthrough, 0.8, "5 kHz should pass through bandpass, ratio=\(passthrough)")
    }

    func testBandpassRejects20kHz() {
        // 20 kHz is above the 10 kHz lowpass cutoff — should be attenuated
        let tone = makeTone(frequency: 20000, duration: 0.5, sampleRate: sampleRate)
        let filtered = conditioner.bandpassFilter(tone, sampleRate: sampleRate, lowCutoff: 1000, highCutoff: 10000)

        let inputEnergy = tone.map { $0 * $0 }.reduce(0, +)
        let outputEnergy = filtered.map { $0 * $0 }.reduce(0, +)
        let attenuation = outputEnergy / inputEnergy

        XCTAssertLessThan(attenuation, 0.01, "20 kHz should be rejected by bandpass, attenuation=\(attenuation)")
    }

    // MARK: - Envelope extraction tests

    func testEnvelopeOf8HzModulatedSignal() {
        // Create a 5 kHz carrier amplitude-modulated at 8 Hz
        // This simulates a 28800 bph watch: ticks create bursts of ~5 kHz energy at 8 Hz
        let duration = 2.0
        let count = Int(duration * sampleRate)
        let carrierFreq = 5000.0
        let modulationFreq = 8.0

        var signal = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            // Half-wave rectified sine modulation to simulate periodic ticks
            let modulator = Float(max(0, sin(2.0 * .pi * modulationFreq * t)))
            let carrier = Float(sin(2.0 * .pi * carrierFreq * t))
            signal[i] = modulator * carrier
        }

        let input = AudioBuffer(samples: signal, sampleRate: sampleRate)
        let conditioned = conditioner.process(input)

        // The envelope should have a strong 8 Hz component.
        // Check by looking at the decimated envelope's periodicity.
        let envelope = conditioned.envelope.samples
        let envRate = conditioned.envelope.sampleRate

        // Find the dominant period in the envelope via autocorrelation
        let expectedPeriodSamples = Int(envRate / modulationFreq)
        let dominantPeriod = findDominantPeriod(envelope, searchRange: (expectedPeriodSamples - 3)...(expectedPeriodSamples + 3))

        XCTAssertNotNil(dominantPeriod, "Should find a dominant period in the envelope")
        if let period = dominantPeriod {
            let measuredHz = envRate / Double(period)
            XCTAssertEqual(measuredHz, modulationFreq, accuracy: 1.0,
                           "Envelope dominant frequency \(measuredHz) Hz should be near \(modulationFreq) Hz")
        }
    }

    // MARK: - Decimation tests

    func testDecimationReducesSampleCount() {
        let input = AudioBuffer(
            samples: makeTone(frequency: 5000, duration: 1.0, sampleRate: sampleRate),
            sampleRate: sampleRate
        )
        let conditioned = conditioner.process(input)

        // Should decimate from 48 kHz to ~1 kHz (factor of 48)
        XCTAssertEqual(conditioned.decimationFactor, 48)
        let expectedEnvelopeCount = input.samples.count / 48
        XCTAssertEqual(conditioned.envelope.samples.count, expectedEnvelopeCount)
        XCTAssertEqual(conditioned.envelope.sampleRate, 1000.0, accuracy: 1.0)
    }

    func testDecimationPreservesLowFrequencyEnergy() {
        // Create a signal with 8 Hz modulation of a 5 kHz carrier
        let duration = 2.0
        let count = Int(duration * sampleRate)
        var signal = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let modulator = Float(0.5 + 0.5 * sin(2.0 * .pi * 8.0 * t))
            let carrier = Float(sin(2.0 * .pi * 5000.0 * t))
            signal[i] = modulator * carrier
        }

        let input = AudioBuffer(samples: signal, sampleRate: sampleRate)
        let conditioned = conditioner.process(input)

        // The envelope should not be all zeros — low-frequency modulation should survive
        let envelopeEnergy = conditioned.envelope.samples.map { $0 * $0 }.reduce(0, +)
        XCTAssertGreaterThan(envelopeEnergy, 0, "Decimated envelope should retain energy")

        // Check variance to confirm the 8 Hz modulation is present (not just DC)
        let mean = conditioned.envelope.samples.reduce(0, +) / Float(conditioned.envelope.samples.count)
        let variance = conditioned.envelope.samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(conditioned.envelope.samples.count)
        XCTAssertGreaterThan(variance, 0, "Envelope should have variance from 8 Hz modulation")
    }

    // MARK: - Full pipeline integration

    func testProcessWithSyntheticWatchSignal() {
        // Use the SyntheticTickGenerator to create a realistic signal
        let generator = SyntheticTickGenerator()
        let params = SyntheticTickParameters(
            beatRate: .bph28800,
            durationSeconds: 5.0,
            snrDb: 40.0
        )
        let signal = generator.generate(parameters: params)
        let conditioned = conditioner.process(signal.buffer)

        // Filtered signal should have the same length and sample rate
        XCTAssertEqual(conditioned.filtered.samples.count, signal.buffer.samples.count)
        XCTAssertEqual(conditioned.filtered.sampleRate, signal.buffer.sampleRate)

        // Envelope should be decimated
        XCTAssertLessThan(conditioned.envelope.samples.count, signal.buffer.samples.count)
        XCTAssertLessThan(conditioned.envelope.sampleRate, signal.buffer.sampleRate)

        // Envelope should have nonzero energy (ticks survived the bandpass)
        let energy = conditioned.envelope.samples.map { $0 * $0 }.reduce(0, +)
        XCTAssertGreaterThan(energy, 0)
    }

    func testFilteredOutputPreservesLength() {
        let samples = makeTone(frequency: 5000, duration: 1.0, sampleRate: sampleRate)
        let input = AudioBuffer(samples: samples, sampleRate: sampleRate)
        let conditioned = conditioner.process(input)
        XCTAssertEqual(conditioned.filtered.samples.count, samples.count)
    }

    // MARK: - Helper: simple autocorrelation peak finder

    private func findDominantPeriod(_ signal: [Float], searchRange: ClosedRange<Int>) -> Int? {
        guard signal.count > searchRange.upperBound else { return nil }
        var bestLag = searchRange.lowerBound
        var bestCorr: Float = -.greatestFiniteMagnitude

        for lag in searchRange {
            var corr: Float = 0
            let n = signal.count - lag
            for i in 0..<n {
                corr += signal[i] * signal[i + lag]
            }
            corr /= Float(n)
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }
        return bestLag
    }
}
