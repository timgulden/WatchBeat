import Foundation
import Accelerate

/// Linear regression on tick times to compute rate error, beat error, and quality metrics.
public struct RateAnalyzer {

    public init() {}

    /// Analyze tick locations to produce the final measurement result.
    ///
    /// - Parameters:
    ///   - tickLocations: Detected tick times and correlation magnitudes.
    ///   - periodEstimate: The detected standard beat rate and measured frequency.
    /// - Returns: Rate error, beat error, quality score, and other diagnostics.
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

        // Linear regression: time = slope * index + intercept
        // slope is the measured beat period
        let n = times.count
        let (slope, intercept) = linearRegression(times: times)

        let measuredPeriod = slope

        // Rate error in seconds per day
        // Positive = watch runs fast (true period shorter than nominal)
        let rateError = (nominalPeriod - measuredPeriod) / nominalPeriod * 86400.0

        // Residuals for quality score
        var residuals = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let predicted = slope * Double(i) + intercept
            residuals[i] = times[i] - predicted
        }

        let residualStd = standardDeviation(residuals)
        // Quality score: saturating function of residual std dev
        // < 0.0001 s (100 us) -> quality ~1.0 (very clean)
        // ~ 0.001 s (1 ms) -> quality ~0.5
        // > 0.01 s (10 ms) -> quality ~0
        let qualityScore = min(1.0, max(0.0, exp(-residualStd / 0.001)))

        // Beat error (mechanical only): asymmetry between tick and tock
        let beatError: Double?
        if !snappedRate.isQuartz && n >= 4 {
            beatError = computeBeatError(times: times, slope: slope, intercept: intercept)
        } else {
            beatError = nil
        }

        // Amplitude proxy: mean of correlation magnitudes
        let amplitudeProxy: Double
        if !magnitudes.isEmpty {
            amplitudeProxy = Double(magnitudes.reduce(0, +)) / Double(magnitudes.count)
        } else {
            amplitudeProxy = 0
        }

        return MeasurementResult(
            snappedRate: snappedRate,
            rateErrorSecondsPerDay: rateError,
            beatErrorMilliseconds: beatError,
            amplitudeProxy: amplitudeProxy,
            qualityScore: qualityScore,
            tickCount: n
        )
    }

    // MARK: - Linear regression

    /// Ordinary least-squares: time[i] = slope * i + intercept
    private func linearRegression(times: [Double]) -> (slope: Double, intercept: Double) {
        let n = Double(times.count)
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXY: Double = 0
        var sumXX: Double = 0

        for i in 0..<times.count {
            let x = Double(i)
            let y = times[i]
            sumX += x
            sumY += y
            sumXY += x * y
            sumXX += x * x
        }

        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 1e-20 else {
            return (slope: 0, intercept: times.first ?? 0)
        }

        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n

        return (slope, intercept)
    }

    // MARK: - Beat error

    /// Beat error: the timing difference between odd and even indexed ticks
    /// relative to the regression line.
    private func computeBeatError(times: [Double], slope: Double, intercept: Double) -> Double {
        var evenResiduals: [Double] = []
        var oddResiduals: [Double] = []

        for i in 0..<times.count {
            let predicted = slope * Double(i) + intercept
            let residual = times[i] - predicted
            if i % 2 == 0 {
                evenResiduals.append(residual)
            } else {
                oddResiduals.append(residual)
            }
        }

        guard !evenResiduals.isEmpty && !oddResiduals.isEmpty else { return 0 }

        let evenMean = evenResiduals.reduce(0, +) / Double(evenResiduals.count)
        let oddMean = oddResiduals.reduce(0, +) / Double(oddResiduals.count)

        // Beat error in milliseconds
        return abs(evenMean - oddMean) * 1000.0
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
