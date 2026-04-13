import Foundation
import Accelerate

/// FFT-based period detection with sub-bin interpolation and snap to standard rate.
///
/// Uses autocorrelation of the decimated envelope to score each candidate standard
/// beat rate. Autocorrelation naturally selects the true fundamental period because
/// the signal repeats at that period but not at sub-multiples.
public struct PeriodEstimator {

    public init() {}

    /// Estimate the beat period from a decimated envelope.
    ///
    /// - Parameter envelope: Decimated envelope from SignalConditioner.
    /// - Returns: Period estimate with measured frequency, snapped rate, and confidence.
    public func estimate(envelope: AudioBuffer) -> PeriodEstimate {
        let samples = envelope.samples
        let sampleRate = envelope.sampleRate
        let n = samples.count

        // Remove DC offset so autocorrelation reflects periodicity, not mean level
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

        // Score each standard beat rate by autocorrelation at its period
        var bestRate = StandardBeatRate.bph28800
        var bestCorr: Float = -.greatestFiniteMagnitude

        for rate in StandardBeatRate.allCases {
            let lagSamples = Int(round(sampleRate / rate.hz))
            guard lagSamples > 0 && lagSamples < n / 2 else { continue }

            // Compute normalized autocorrelation at this lag
            let overlap = n - lagSamples
            var corr: Float = 0
            vDSP_dotpr(centered, 1, Array(centered[lagSamples...]), 1, &corr, vDSP_Length(overlap))
            let normalizedCorr = corr / zeroPower

            if normalizedCorr > bestCorr {
                bestCorr = normalizedCorr
                bestRate = rate
            }
        }

        // Refine the frequency with parabolic interpolation around the best lag
        let bestLag = Int(round(sampleRate / bestRate.hz))
        let measuredHz = refineFrequency(
            signal: centered, sampleRate: sampleRate, approximateLag: bestLag
        )

        // Confidence is primarily the absolute autocorrelation strength at the
        // winning lag. A clean periodic signal produces normalized autocorrelation
        // near 1.0; noise produces values near 0. This directly indicates whether
        // there is a detectable periodic signal, regardless of which rate wins.
        let confidence = min(1.0, max(0.0, Double(bestCorr)))

        return PeriodEstimate(
            measuredHz: measuredHz,
            snappedRate: bestRate,
            confidence: confidence
        )
    }

    // MARK: - Frequency refinement

    /// Parabolic interpolation around the autocorrelation peak near `approximateLag`
    /// for sub-sample period precision.
    private func refineFrequency(signal: [Float], sampleRate: Double, approximateLag: Int) -> Double {
        let n = signal.count
        // Search a small window around the expected lag
        let searchRadius = max(2, approximateLag / 20)
        let minLag = max(1, approximateLag - searchRadius)
        let maxLag = min(n / 2 - 1, approximateLag + searchRadius)

        // Find the peak autocorrelation in the search window
        var peakLag = approximateLag
        var peakCorr: Float = -.greatestFiniteMagnitude

        for lag in minLag...maxLag {
            let overlap = n - lag
            var corr: Float = 0
            vDSP_dotpr(signal, 1, Array(signal[lag...]), 1, &corr, vDSP_Length(overlap))
            if corr > peakCorr {
                peakCorr = corr
                peakLag = lag
            }
        }

        // Parabolic interpolation using neighbors
        guard peakLag > minLag && peakLag < maxLag else {
            return sampleRate / Double(peakLag)
        }

        let overlap = n - peakLag
        var corrMinus: Float = 0
        var corrPlus: Float = 0
        vDSP_dotpr(signal, 1, Array(signal[(peakLag - 1)...]), 1, &corrMinus, vDSP_Length(overlap))
        vDSP_dotpr(signal, 1, Array(signal[(peakLag + 1)...]), 1, &corrPlus, vDSP_Length(min(overlap, n - peakLag - 1)))

        let denom = corrMinus - 2.0 * peakCorr + corrPlus
        let offset: Float
        if abs(denom) > 1e-10 {
            offset = 0.5 * (corrMinus - corrPlus) / denom
        } else {
            offset = 0
        }

        let refinedLag = Double(peakLag) + Double(offset)
        return sampleRate / refinedLag
    }
}
