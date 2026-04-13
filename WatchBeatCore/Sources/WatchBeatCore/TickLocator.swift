import Foundation
import Accelerate

/// Result of tick localization: sub-sample tick times and correlation magnitudes.
public struct TickLocations: Sendable {
    /// Sub-sample-precise tick times in seconds.
    public let tickTimesSeconds: [Double]
    /// Peak energy magnitude at each detected tick.
    public let correlationMagnitudes: [Float]
}

/// Locates individual ticks in the filtered signal with sub-sample precision.
///
/// Uses a two-pass approach:
/// 1. Coarse pass: find energy peaks in the squared signal at expected beat spacing.
/// 2. Refinement: parabolic interpolation for sub-sample precision.
///
/// By detecting energy peaks directly (rather than pair-template correlation),
/// every individual tick and tock is found, preserving beat error asymmetry.
public struct TickLocator {

    public init() {}

    /// Locate ticks in the filtered signal.
    public func locate(
        filtered: AudioBuffer,
        template: TickTemplate,
        periodEstimate: PeriodEstimate
    ) -> TickLocations {
        let signal = filtered.samples
        let sampleRate = filtered.sampleRate
        let n = signal.count

        let beatPeriodSamples = sampleRate / periodEstimate.measuredHz
        guard beatPeriodSamples > 2 && n > Int(beatPeriodSamples) * 2 else {
            return TickLocations(tickTimesSeconds: [], correlationMagnitudes: [])
        }

        // Compute smoothed energy envelope for tick detection.
        // Square the signal and smooth with a short window (~1ms) to get
        // a clean energy profile where each tick appears as a distinct peak.
        var squaredSignal = [Float](repeating: 0, count: n)
        vDSP_vsq(signal, 1, &squaredSignal, 1, vDSP_Length(n))

        let smoothWindow = max(3, Int(sampleRate * 0.001)) | 1 // ~1ms, ensure odd
        let halfSmooth = smoothWindow / 2
        let energyLen = n - smoothWindow + 1

        guard energyLen > 0 else {
            return TickLocations(tickTimesSeconds: [], correlationMagnitudes: [])
        }

        // Compute moving-average energy
        var energy = [Float](repeating: 0, count: energyLen)
        for i in 0..<energyLen {
            var sum: Float = 0
            vDSP_sve(squaredSignal.withUnsafeBufferPointer { $0.baseAddress! + i },
                     1, &sum, vDSP_Length(smoothWindow))
            energy[i] = sum
        }

        // Establish threshold using percentiles rather than max.
        // Max energy can be dominated by a single handling-noise spike,
        // making the threshold unreachable for real tick peaks.
        // Use the 98th percentile as the "reference high" and set the
        // threshold just above the noise floor (75th percentile).
        let sortedEnergy = energy.sorted()
        let p50 = sortedEnergy[sortedEnergy.count / 2]
        let p75 = sortedEnergy[sortedEnergy.count * 3 / 4]
        let p98 = sortedEnergy[min(sortedEnergy.count - 1, sortedEnergy.count * 98 / 100)]
        // Threshold: halfway between the noise floor (p50) and the tick energy level (p98)
        // This is much more robust than using max, which can be a single spike
        let threshold = p50 + 0.3 * (p98 - p50)
        // Ensure threshold is at least slightly above the 75th percentile
        let effectiveThreshold = max(threshold, p75 * 1.2)

        // Find peaks at expected beat spacing
        let tolerance = 0.3 // ±30% to accommodate beat error
        let minSpacing = Int(beatPeriodSamples * (1.0 - tolerance))
        let maxSpacing = Int(beatPeriodSamples * (1.0 + tolerance))

        var peakIndices: [Int] = []
        var peakMagnitudes: [Float] = []

        // Find first strong energy peak
        var searchStart = 0
        if let firstPeak = findEnergyPeak(in: energy, from: 0,
                                           to: min(energyLen, Int(beatPeriodSamples * 2)),
                                           threshold: effectiveThreshold) {
            peakIndices.append(firstPeak)
            peakMagnitudes.append(energy[firstPeak])
            searchStart = firstPeak
        } else {
            return TickLocations(tickTimesSeconds: [], correlationMagnitudes: [])
        }

        // Find subsequent peaks at beat spacing
        while searchStart + minSpacing < energyLen {
            let windowStart = searchStart + minSpacing
            let windowEnd = min(energyLen, searchStart + maxSpacing + 1)

            if let peak = findEnergyPeak(in: energy, from: windowStart,
                                          to: windowEnd, threshold: threshold) {
                peakIndices.append(peak)
                peakMagnitudes.append(energy[peak])
                searchStart = peak
            } else {
                searchStart += Int(beatPeriodSamples)
            }
        }

        // Sub-sample refinement via parabolic interpolation on energy
        var tickTimes: [Double] = []
        var refinedMagnitudes: [Float] = []

        for (i, peakIdx) in peakIndices.enumerated() {
            // The energy index is offset by halfSmooth from the signal index
            let signalIdx = peakIdx + halfSmooth

            let refinedSample: Double
            if peakIdx > 0 && peakIdx < energyLen - 1 {
                let alpha = energy[peakIdx - 1]
                let beta = energy[peakIdx]
                let gamma = energy[peakIdx + 1]
                let denom = alpha - 2.0 * beta + gamma
                if abs(denom) > 1e-10 {
                    let offset = 0.5 * (alpha - gamma) / denom
                    refinedSample = Double(signalIdx) + Double(offset)
                } else {
                    refinedSample = Double(signalIdx)
                }
            } else {
                refinedSample = Double(signalIdx)
            }

            tickTimes.append(refinedSample / sampleRate)
            refinedMagnitudes.append(peakMagnitudes[i])
        }

        return TickLocations(tickTimesSeconds: tickTimes, correlationMagnitudes: refinedMagnitudes)
    }

    // MARK: - Helpers

    /// Find the index of the maximum value in energy[from..<to] that exceeds threshold.
    private func findEnergyPeak(in energy: [Float], from: Int, to: Int, threshold: Float) -> Int? {
        guard from < to && from >= 0 && to <= energy.count else { return nil }
        var bestIdx = from
        var bestVal = energy[from]
        for i in (from + 1)..<to {
            if energy[i] > bestVal {
                bestVal = energy[i]
                bestIdx = i
            }
        }
        return bestVal >= threshold ? bestIdx : nil
    }
}
