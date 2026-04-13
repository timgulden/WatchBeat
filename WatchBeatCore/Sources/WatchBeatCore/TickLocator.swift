import Foundation
import Accelerate

/// Result of tick localization: sub-sample tick times and correlation magnitudes.
public struct TickLocations: Sendable {
    /// Sub-sample-precise tick times in seconds.
    public let tickTimesSeconds: [Double]
    /// Peak cross-correlation magnitude at each detected tick.
    public let correlationMagnitudes: [Float]
}

/// Cross-correlates the tick template against the raw signal to locate individual ticks
/// with sub-sample precision.
public struct TickLocator {

    public init() {}

    /// Locate ticks in the filtered signal using the template.
    ///
    /// - Parameters:
    ///   - filtered: Bandpass-filtered signal at full sample rate.
    ///   - template: Averaged tick template from TemplateBuilder.
    ///   - periodEstimate: Period estimate to determine expected tick spacing.
    /// - Returns: Located tick times and their correlation magnitudes.
    public func locate(
        filtered: AudioBuffer,
        template: TickTemplate,
        periodEstimate: PeriodEstimate
    ) -> TickLocations {
        let signal = filtered.samples
        let sampleRate = filtered.sampleRate
        let templateSamples = template.samples
        let templateLen = templateSamples.count

        guard signal.count > templateLen else {
            return TickLocations(tickTimesSeconds: [], correlationMagnitudes: [])
        }

        // Cross-correlate template against the signal
        let corrLen = signal.count - templateLen + 1
        var correlation = [Float](repeating: 0, count: corrLen)

        // vDSP_conv computes correlation (note: it reverses the filter kernel,
        // but since we want correlation with the template as-is, we pass the
        // template reversed so vDSP_conv effectively does correlation)
        var reversedTemplate = [Float](repeating: 0, count: templateLen)
        for i in 0..<templateLen {
            reversedTemplate[i] = templateSamples[templateLen - 1 - i]
        }

        vDSP_conv(signal, 1, reversedTemplate, 1, &correlation, 1,
                  vDSP_Length(corrLen), vDSP_Length(templateLen))

        // Find peaks at expected tick spacing
        // For mechanical watches, the template spans 2 beats (tick+tock pair),
        // but correlation peaks appear at every single beat because each beat
        // matches part of the template. So we search at 1-beat spacing.
        let beatPeriodSamples = sampleRate / periodEstimate.measuredHz
        let tolerance = 0.25 // ±25% tolerance on expected spacing

        let minSpacing = Int(beatPeriodSamples * (1.0 - tolerance))
        let maxSpacing = Int(beatPeriodSamples * (1.0 + tolerance))

        // Find all peaks using a greedy approach:
        // Start from the beginning, find the highest correlation within
        // the first expected-period window, then search for subsequent peaks.
        var peakIndices: [Int] = []
        var peakMagnitudes: [Float] = []

        // Establish a threshold: median + some factor of the range
        let sortedCorr = correlation.sorted()
        let medianCorr = sortedCorr[sortedCorr.count / 2]
        let maxCorr = sortedCorr.last ?? 0
        let threshold = medianCorr + 0.2 * (maxCorr - medianCorr)

        // Find the first strong peak
        var searchStart = 0
        if let firstPeak = findLocalMax(in: correlation, from: searchStart,
                                         to: min(corrLen, Int(beatPeriodSamples * 2)),
                                         threshold: threshold) {
            peakIndices.append(firstPeak)
            peakMagnitudes.append(correlation[firstPeak])
            searchStart = firstPeak
        } else {
            return TickLocations(tickTimesSeconds: [], correlationMagnitudes: [])
        }

        // Find subsequent peaks at expected spacing
        while searchStart + minSpacing < corrLen {
            let windowStart = searchStart + minSpacing
            let windowEnd = min(corrLen, searchStart + maxSpacing + 1)

            if let peak = findLocalMax(in: correlation, from: windowStart,
                                        to: windowEnd, threshold: threshold) {
                peakIndices.append(peak)
                peakMagnitudes.append(correlation[peak])
                searchStart = peak
            } else {
                // No peak found in this window — skip ahead
                searchStart += Int(beatPeriodSamples)
            }
        }

        // Sub-sample refinement via parabolic interpolation
        var tickTimes: [Double] = []
        var refinedMagnitudes: [Float] = []

        for (i, peakIdx) in peakIndices.enumerated() {
            let refinedSample: Double
            if peakIdx > 0 && peakIdx < corrLen - 1 {
                let alpha = correlation[peakIdx - 1]
                let beta = correlation[peakIdx]
                let gamma = correlation[peakIdx + 1]
                let denom = alpha - 2.0 * beta + gamma
                if abs(denom) > 1e-10 {
                    let offset = 0.5 * (alpha - gamma) / denom
                    refinedSample = Double(peakIdx) + Double(offset)
                } else {
                    refinedSample = Double(peakIdx)
                }
            } else {
                refinedSample = Double(peakIdx)
            }

            // The correlation peak corresponds to the start of the template alignment.
            // Tick time is at the center of the template's first beat.
            let tickTime = refinedSample / sampleRate
            tickTimes.append(tickTime)
            refinedMagnitudes.append(peakMagnitudes[i])
        }

        return TickLocations(tickTimesSeconds: tickTimes, correlationMagnitudes: refinedMagnitudes)
    }

    // MARK: - Helpers

    /// Find the index of the maximum value in correlation[from..<to] that exceeds threshold.
    private func findLocalMax(in correlation: [Float], from: Int, to: Int, threshold: Float) -> Int? {
        guard from < to && from >= 0 && to <= correlation.count else { return nil }
        var bestIdx = from
        var bestVal = correlation[from]
        for i in (from + 1)..<to {
            if correlation[i] > bestVal {
                bestVal = correlation[i]
                bestIdx = i
            }
        }
        return bestVal >= threshold ? bestIdx : nil
    }
}
