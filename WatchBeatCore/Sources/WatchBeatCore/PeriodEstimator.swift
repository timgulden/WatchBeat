import Foundation
import Accelerate

/// FFT-based period measurement with sub-bin precision.
///
/// Two-stage approach:
/// 1. Rate identification: autocorrelation of the envelope scores each candidate
///    standard rate. The correct rate has the highest normalized autocorrelation.
/// 2. Precise frequency: FFT of the envelope with parabolic interpolation around
///    the peak near the identified rate gives sub-bin frequency resolution.
///    The deviation from nominal frequency directly gives rate error in s/day.
struct PeriodEstimator {

    init() {}

    /// Estimate the beat period from a decimated envelope.
    public func estimate(envelope: AudioBuffer) -> PeriodEstimate {
        let samples = envelope.samples
        let sampleRate = envelope.sampleRate
        let n = samples.count

        // Remove DC offset
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(n))
        var centered = [Float](repeating: 0, count: n)
        var negMean = -mean
        vDSP_vsadd(samples, 1, &negMean, &centered, 1, vDSP_Length(n))

        // Compute autocorrelation at zero lag for normalization
        var zeroPower: Float = 0
        vDSP_dotpr(centered, 1, centered, 1, &zeroPower, vDSP_Length(n))
        guard zeroPower > 0 else {
            return PeriodEstimate(measuredHz: 0, snappedRate: .bph28800, confidence: 0)
        }

        // Stage 1: Score each standard rate by autocorrelation
        var rateScores: [(rate: StandardBeatRate, corr: Float)] = []

        for rate in StandardBeatRate.allCases {
            let lagSamples = Int(round(sampleRate / rate.hz))
            guard lagSamples > 0 && lagSamples < n / 2 else { continue }

            let overlap = n - lagSamples
            var corr: Float = 0
            vDSP_dotpr(centered, 1, Array(centered[lagSamples...]), 1, &corr, vDSP_Length(overlap))
            let normalizedCorr = corr / zeroPower
            rateScores.append((rate, normalizedCorr))
        }

        rateScores.sort { $0.corr > $1.corr }

        // Sub-harmonic preference: prefer higher rate if it has strong correlation
        var bestRate = rateScores.first?.rate ?? .bph28800
        var bestCorr = rateScores.first?.corr ?? 0

        if let topScore = rateScores.first {
            for candidate in rateScores {
                let ratio = candidate.rate.hz / topScore.rate.hz
                if ratio > 1.5 && ratio < 2.5 {
                    let relativeStrength = candidate.corr / topScore.corr
                    if relativeStrength > 0.7 {
                        bestRate = candidate.rate
                        bestCorr = candidate.corr
                        break
                    }
                }
            }
        }

        // Stage 2: Precise frequency measurement via FFT
        let measuredHz = measureFrequencyViaFFT(
            samples: centered, sampleRate: sampleRate, nearHz: bestRate.hz
        )

        let confidence = min(1.0, max(0.0, Double(bestCorr)))

        return PeriodEstimate(
            measuredHz: measuredHz,
            snappedRate: bestRate,
            confidence: confidence
        )
    }

    // MARK: - FFT-based frequency measurement

    /// Compute FFT of the signal and find the precise frequency of the peak
    /// nearest to `nearHz`, using parabolic interpolation for sub-bin resolution.
    func measureFrequencyViaFFT(samples: [Float], sampleRate: Double, nearHz: Double) -> Double {
        let n = samples.count

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: n)
        vDSP_hann_window(&windowed, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, windowed, 1, &windowed, 1, vDSP_Length(n))

        // Zero-pad to next power of two
        let fftLength = nextPowerOfTwo(n)
        var padded = [Float](repeating: 0, count: fftLength)
        padded.replaceSubrange(0..<n, with: windowed)

        // FFT
        let log2n = vDSP_Length(log2(Double(fftLength)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nearHz
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = fftLength / 2
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)

        padded.withUnsafeBufferPointer { buf in
            for i in 0..<halfN {
                realPart[i] = buf[2 * i]
                imagPart[i] = buf[2 * i + 1]
            }
        }

        var magnitudes = [Float](repeating: 0, count: halfN)

        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        // sqrt for magnitude (not power)
        var sqrtMagnitudes = [Float](repeating: 0, count: halfN)
        var count32 = Int32(halfN)
        vvsqrtf(&sqrtMagnitudes, magnitudes, &count32)

        // Find peak near the target frequency
        let freqResolution = sampleRate / Double(fftLength)
        let targetBin = nearHz / freqResolution
        let searchRadius = max(3, Int(targetBin * 0.15)) // ±15% around target
        let minBin = max(1, Int(targetBin) - searchRadius)
        let maxBin = min(halfN - 2, Int(targetBin) + searchRadius)

        guard minBin < maxBin else { return nearHz }

        var peakBin = minBin
        var peakMag = sqrtMagnitudes[minBin]
        for bin in (minBin + 1)...maxBin {
            if sqrtMagnitudes[bin] > peakMag {
                peakMag = sqrtMagnitudes[bin]
                peakBin = bin
            }
        }

        // Parabolic interpolation for sub-bin precision
        guard peakBin > minBin && peakBin < maxBin else {
            return Double(peakBin) * freqResolution
        }

        let alpha = sqrtMagnitudes[peakBin - 1]
        let beta = sqrtMagnitudes[peakBin]
        let gamma = sqrtMagnitudes[peakBin + 1]

        let denom = alpha - 2.0 * beta + gamma
        let offset: Float
        if abs(denom) > 1e-10 {
            offset = 0.5 * (alpha - gamma) / denom
        } else {
            offset = 0
        }

        return (Double(peakBin) + Double(offset)) * freqResolution
    }

    // MARK: - Helpers

    private func nextPowerOfTwo(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        return v + 1
    }
}
