import Foundation
import Accelerate

/// Linear regression on tick times to compute rate error, beat error, and quality metrics.
///
/// Robust to missing ticks and outliers:
/// 1. Assigns each detected tick a beat number based on expected spacing (handles gaps).
/// 2. Performs iterative outlier rejection using median absolute deviation.
/// 3. Refits regression on clean ticks only.
public struct RateAnalyzer {

    /// Maximum number of outlier rejection passes.
    private let maxOutlierPasses = 3

    public init() {}

    /// Analyze tick locations to produce the final measurement result.
    public func analyze(
        tickLocations: TickLocations,
        periodEstimate: PeriodEstimate
    ) -> MeasurementResult {
        let times = tickLocations.tickTimesSeconds
        let magnitudes = tickLocations.correlationMagnitudes
        let snappedRate = periodEstimate.snappedRate
        let nominalPeriod = snappedRate.nominalPeriodSeconds

        guard times.count >= 3 else {
            return MeasurementResult(
                snappedRate: snappedRate,
                rateErrorSecondsPerDay: 0,
                beatErrorMilliseconds: nil,
                amplitudeProxy: 0,
                qualityScore: 0,
                tickCount: times.count
            )
        }

        // Step 1: Assign beat numbers based on expected period.
        // This handles missing ticks: if beats 5 and 6 are missing, the beat
        // numbers jump from 4 to 7 and the regression correctly accounts for the gap.
        let beatNumbers = assignBeatNumbers(times: times, expectedPeriod: nominalPeriod)

        // Step 2: Initial regression on beat numbers
        var activeMask = [Bool](repeating: true, count: times.count)
        var slope: Double = 0
        var intercept: Double = 0

        (slope, intercept) = regressionOnActive(times: times, beatNumbers: beatNumbers, mask: activeMask)

        // Step 3: Iterative outlier rejection.
        // Use a threshold based on the beat period: any tick whose residual exceeds
        // 25% of a beat period is almost certainly a noise peak, not a real tick.
        // This is robust to beat error (which creates systematic ±few ms residuals
        // that are tiny compared to 25% of a beat period).
        let outlierThreshold = nominalPeriod * 0.25

        for _ in 0..<maxOutlierPasses {
            let residuals = computeResiduals(times: times, beatNumbers: beatNumbers,
                                              slope: slope, intercept: intercept, mask: activeMask)

            var changed = false
            for i in 0..<times.count {
                if activeMask[i] && abs(residuals[i]) > outlierThreshold {
                    activeMask[i] = false
                    changed = true
                }
            }

            guard changed else { break }

            let activeCount = activeMask.filter { $0 }.count
            guard activeCount >= 3 else { break }

            (slope, intercept) = regressionOnActive(times: times, beatNumbers: beatNumbers, mask: activeMask)
        }

        let measuredPeriod = slope
        let activeCount = activeMask.filter { $0 }.count

        // Rate error in seconds per day
        // Positive = watch runs fast (true period shorter than nominal)
        let rateError = (nominalPeriod - measuredPeriod) / nominalPeriod * 86400.0

        // Quality score from residuals of clean ticks
        let cleanResiduals = computeResiduals(times: times, beatNumbers: beatNumbers,
                                               slope: slope, intercept: intercept, mask: activeMask)
        let activeResiduals = zip(cleanResiduals, activeMask).compactMap { $0.1 ? $0.0 : nil }
        let residualStd = standardDeviation(activeResiduals)
        let qualityScore = min(1.0, max(0.0, exp(-residualStd / 0.001)))

        // Beat error (mechanical only)
        let beatError: Double?
        if !snappedRate.isQuartz && activeCount >= 4 {
            beatError = computeBeatError(times: times, beatNumbers: beatNumbers,
                                          slope: slope, intercept: intercept, mask: activeMask)
        } else {
            beatError = nil
        }

        // Amplitude proxy: mean of correlation magnitudes for active ticks
        let activeMagnitudes = zip(magnitudes, activeMask).compactMap { $0.1 ? $0.0 : nil }
        let amplitudeProxy: Double
        if !activeMagnitudes.isEmpty {
            amplitudeProxy = Double(activeMagnitudes.reduce(0, +)) / Double(activeMagnitudes.count)
        } else {
            amplitudeProxy = 0
        }

        return MeasurementResult(
            snappedRate: snappedRate,
            rateErrorSecondsPerDay: rateError,
            beatErrorMilliseconds: beatError,
            amplitudeProxy: amplitudeProxy,
            qualityScore: qualityScore,
            tickCount: activeCount
        )
    }

    // MARK: - Beat number assignment

    /// Assign each detected tick time its most likely beat number.
    /// Beat 0 is the first tick; subsequent ticks are assigned the nearest integer
    /// multiple of the expected period from the first tick.
    private func assignBeatNumbers(times: [Double], expectedPeriod: Double) -> [Int] {
        guard let firstTime = times.first else { return [] }
        return times.map { time in
            Int(round((time - firstTime) / expectedPeriod))
        }
    }

    // MARK: - Regression

    /// OLS regression: time = slope * beatNumber + intercept, using only active ticks.
    private func regressionOnActive(times: [Double], beatNumbers: [Int], mask: [Bool]) -> (slope: Double, intercept: Double) {
        var sumX: Double = 0, sumY: Double = 0, sumXY: Double = 0, sumXX: Double = 0
        var count: Double = 0

        for i in 0..<times.count where mask[i] {
            let x = Double(beatNumbers[i])
            let y = times[i]
            sumX += x
            sumY += y
            sumXY += x * y
            sumXX += x * x
            count += 1
        }

        let denom = count * sumXX - sumX * sumX
        guard abs(denom) > 1e-20 && count >= 2 else {
            return (slope: 0, intercept: times.first ?? 0)
        }

        let slope = (count * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / count
        return (slope, intercept)
    }

    /// Compute residuals for all ticks (0 for inactive).
    private func computeResiduals(times: [Double], beatNumbers: [Int],
                                   slope: Double, intercept: Double, mask: [Bool]) -> [Double] {
        var residuals = [Double](repeating: 0, count: times.count)
        for i in 0..<times.count where mask[i] {
            let predicted = slope * Double(beatNumbers[i]) + intercept
            residuals[i] = times[i] - predicted
        }
        return residuals
    }

    // MARK: - Beat error

    private func computeBeatError(times: [Double], beatNumbers: [Int],
                                   slope: Double, intercept: Double, mask: [Bool]) -> Double {
        var residualByBeat: [Int: Double] = [:]
        for i in 0..<times.count where mask[i] {
            let predicted = slope * Double(beatNumbers[i]) + intercept
            residualByBeat[beatNumbers[i]] = times[i] - predicted
        }
        return (BeatError.meanPairedAbsDifference(residualsByBeat: residualByBeat) ?? 0) * 1000.0
    }

    // MARK: - Statistics

    private func standardDeviation(_ values: [Double]) -> Double {
        let n = Double(values.count)
        guard n > 1 else { return 0 }
        let mean = values.reduce(0, +) / n
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / (n - 1)
        return sqrt(variance)
    }

}
