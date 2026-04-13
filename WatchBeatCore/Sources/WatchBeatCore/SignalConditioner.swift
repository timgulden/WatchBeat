import Foundation
import Accelerate

/// Output of signal conditioning: the decimated envelope for period estimation,
/// plus the bandpass-filtered signal for downstream tick localization.
public struct ConditionedSignal: Sendable {
    /// Bandpass-filtered signal at the original sample rate.
    public let filtered: AudioBuffer
    /// Decimated envelope suitable for period estimation.
    public let envelope: AudioBuffer
    /// The decimation factor used (original rate / envelope rate).
    public let decimationFactor: Int
}

/// Bandpass filters, extracts envelope, and decimates the signal for period estimation.
public struct SignalConditioner {

    public init() {}

    /// Process a raw audio buffer into a conditioned signal.
    ///
    /// - Parameter input: Raw audio from the microphone.
    /// - Returns: Bandpass-filtered signal and decimated envelope.
    public func process(_ input: AudioBuffer) -> ConditionedSignal {
        // Stage 1: Bandpass filter (1 kHz – 10 kHz, 4th-order Butterworth)
        let filtered = bandpassFilter(
            input.samples,
            sampleRate: input.sampleRate,
            lowCutoff: 1000.0,
            highCutoff: 10000.0
        )

        // Stage 2: Envelope extraction (rectify + lowpass at 50 Hz)
        let rectified = fullWaveRectify(filtered)
        let envelopeFull = lowpassFilter(rectified, sampleRate: input.sampleRate, cutoff: 50.0)

        // Stage 3: Decimate to ~1 kHz
        let decimationFactor = max(1, Int(input.sampleRate / 1000.0))
        let decimated = decimate(envelopeFull, factor: decimationFactor)
        let envelopeRate = input.sampleRate / Double(decimationFactor)

        return ConditionedSignal(
            filtered: AudioBuffer(samples: filtered, sampleRate: input.sampleRate),
            envelope: AudioBuffer(samples: decimated, sampleRate: envelopeRate),
            decimationFactor: decimationFactor
        )
    }

    // MARK: - Bandpass filter

    /// 4th-order Butterworth bandpass implemented as two cascaded biquad sections
    /// for each of the highpass and lowpass halves.
    func bandpassFilter(_ samples: [Float], sampleRate: Double, lowCutoff: Double, highCutoff: Double) -> [Float] {
        // Highpass at lowCutoff, then lowpass at highCutoff
        // Each is 2nd-order Butterworth, cascaded twice for 4th-order
        let highpassed = applyBiquadCascade(samples, coefficients: butterworthHighpass(cutoff: lowCutoff, sampleRate: sampleRate))
        let bandpassed = applyBiquadCascade(highpassed, coefficients: butterworthLowpass(cutoff: highCutoff, sampleRate: sampleRate))
        return bandpassed
    }

    // MARK: - Envelope extraction

    func fullWaveRectify(_ samples: [Float]) -> [Float] {
        var result = samples
        vDSP_vabs(samples, 1, &result, 1, vDSP_Length(samples.count))
        return result
    }

    /// 4th-order Butterworth lowpass for envelope smoothing.
    func lowpassFilter(_ samples: [Float], sampleRate: Double, cutoff: Double) -> [Float] {
        applyBiquadCascade(samples, coefficients: butterworthLowpass(cutoff: cutoff, sampleRate: sampleRate))
    }

    // MARK: - Decimation

    func decimate(_ samples: [Float], factor: Int) -> [Float] {
        guard factor > 1 else { return samples }
        let outputCount = samples.count / factor
        guard outputCount > 0 else { return [] }
        var result = [Float](repeating: 0.0, count: outputCount)
        // Simple pick-every-Nth decimation. The preceding lowpass at 50 Hz
        // serves as the anti-alias filter, so no additional filtering needed.
        for i in 0..<outputCount {
            result[i] = samples[i * factor]
        }
        return result
    }

    // MARK: - Biquad filter infrastructure

    /// Coefficients for two cascaded 2nd-order sections (4th-order total).
    /// Each section is [b0, b1, b2, a1, a2] (vDSP_biquad convention with a0=1 normalized out).
    private struct BiquadCascade {
        let sections: [[Double]] // each section: [b0, b1, b2, a1, a2]
    }

    /// Apply a cascade of biquad sections using vDSP_biquad.
    private func applyBiquadCascade(_ samples: [Float], coefficients: BiquadCascade) -> [Float] {
        var output = samples
        let n = vDSP_Length(samples.count)

        for section in coefficients.sections {
            // vDSP_biquad expects coefficients as [b0, b1, b2, a1, a2]
            var coeffs = section.map { Double($0) }
            var delays = [Double](repeating: 0.0, count: 2 + 2) // 2 input delays + 2 output delays
            var input = output.map { Double($0) }
            var out = [Double](repeating: 0.0, count: output.count)

            let setup = vDSP_biquad_CreateSetupD(&coeffs, 1)
            defer { vDSP_biquad_DestroySetupD(setup) }

            if let setup = setup {
                vDSP_biquadD(setup, &delays, &input, 1, &out, 1, n)
                output = out.map { Float($0) }
            } else {
                output = manualBiquad(input: output, b0: Float(section[0]), b1: Float(section[1]),
                                      b2: Float(section[2]), a1: Float(section[3]), a2: Float(section[4]))
            }
        }
        return output
    }

    private func manualBiquad(input: [Float], b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) -> [Float] {
        var output = [Float](repeating: 0.0, count: input.count)
        var x1: Float = 0, x2: Float = 0
        var y1: Float = 0, y2: Float = 0
        for i in 0..<input.count {
            let x0 = input[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            output[i] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
        return output
    }

    // MARK: - Butterworth coefficient computation

    /// 4th-order Butterworth lowpass as two cascaded 2nd-order sections.
    private func butterworthLowpass(cutoff: Double, sampleRate: Double) -> BiquadCascade {
        // Pre-warp the cutoff frequency
        let wc = tan(.pi * cutoff / sampleRate)

        // 4th-order Butterworth pole angles: pi/8 and 3*pi/8 from negative real axis
        // This gives two conjugate pairs with Q values:
        let q1 = 1.0 / (2.0 * cos(.pi / 8.0))   // Q ≈ 0.541
        let q2 = 1.0 / (2.0 * cos(3.0 * .pi / 8.0)) // Q ≈ 1.307

        return BiquadCascade(sections: [
            lowpassSection(wc: wc, q: q1),
            lowpassSection(wc: wc, q: q2),
        ])
    }

    /// 4th-order Butterworth highpass as two cascaded 2nd-order sections.
    private func butterworthHighpass(cutoff: Double, sampleRate: Double) -> BiquadCascade {
        let wc = tan(.pi * cutoff / sampleRate)

        let q1 = 1.0 / (2.0 * cos(.pi / 8.0))
        let q2 = 1.0 / (2.0 * cos(3.0 * .pi / 8.0))

        return BiquadCascade(sections: [
            highpassSection(wc: wc, q: q1),
            highpassSection(wc: wc, q: q2),
        ])
    }

    /// Single 2nd-order lowpass section via bilinear transform.
    /// Returns [b0, b1, b2, a1, a2] with a0 normalized to 1.
    private func lowpassSection(wc: Double, q: Double) -> [Double] {
        let wc2 = wc * wc
        let norm = 1.0 + wc / q + wc2

        let b0 = wc2 / norm
        let b1 = 2.0 * wc2 / norm
        let b2 = wc2 / norm
        let a1 = 2.0 * (wc2 - 1.0) / norm
        let a2 = (1.0 - wc / q + wc2) / norm

        return [b0, b1, b2, a1, a2]
    }

    /// Single 2nd-order highpass section via bilinear transform.
    /// Returns [b0, b1, b2, a1, a2] with a0 normalized to 1.
    private func highpassSection(wc: Double, q: Double) -> [Double] {
        let wc2 = wc * wc
        let norm = 1.0 + wc / q + wc2

        let b0 = 1.0 / norm
        let b1 = -2.0 / norm
        let b2 = 1.0 / norm
        let a1 = 2.0 * (wc2 - 1.0) / norm
        let a2 = (1.0 - wc / q + wc2) / norm

        return [b0, b1, b2, a1, a2]
    }
}
