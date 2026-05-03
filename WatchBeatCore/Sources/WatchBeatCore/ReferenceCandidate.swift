import Foundation

/// One rate candidate evaluated by the Reference picker. Carries both the
/// raw fit data (slope, intercept, residuals) and the derived statistics
/// (per-class σ, beat-error asymmetry, SNR) needed by the composite score.
///
/// The Reference picker generates one of these per standard rate band,
/// then chooses the highest-scoring as the winner.
struct ReferenceCandidate {
    let snappedRate: StandardBeatRate
    let fHz: Double
    let phi: Double
    let beatPositions: [Double]
    let slope: Double
    let intercept: Double
    let residualsMs: [Double]
    let evenMean: Double, oddMean: Double
    let evenStd: Double, oddStd: Double
    let avgClassStd: Double
    let beAsymmetryMs: Double
    let tickEnergies: [Float]
    let gapEnergies: [Float]
    let medianTick: Float, medianGap: Float
    let snr: Double
    let confirmedFraction: Double
    let cleanedConfirmed: [Int]

    /// Composite score for ranking candidate rates. Four factors:
    ///   confirmedFraction → "did the picker find ticks at this rate?"
    ///   q (SNR-based)     → "is the audio clean enough to read?"
    ///   sigmaPen          → "are the picks consistent timing-wise?"
    ///   rateConsistency   → "does the regression slope match this
    ///                        candidate's expected period?" — catches
    ///                        harmonic confusion. A 36000-bph candidate
    ///                        running on a 21600-bph watch picks every
    ///                        other real tick; its confirmed-only
    ///                        regression has a slope that matches
    ///                        21600's period, NOT 36000's. Killing
    ///                        score when slope/expected diverges by
    ///                        more than 10% removes the harmonic.
    ///
    /// sigmaPen uses σ² because on lossy recordings the right rate's
    /// σ may be 30-40 ms; a linear penalty barely separates it from a
    /// wrong rate's 50 ms. Quadratic helps without going zero.
    ///   σ = 5  → sigmaPen = 0.50
    ///   σ = 10 → sigmaPen = 0.33
    ///   σ = 30 → sigmaPen = 0.053
    ///   σ = 50 → sigmaPen = 0.020
    var score: Double {
        let q = max(0.0, min(1.0, 1.0 - exp(-snr / 10.0)))
        let sigmaPen = 1.0 / (1.0 + (avgClassStd * avgClassStd) / 50.0)
        let expectedPeriod = 1.0 / fHz
        let slopeRatio = expectedPeriod > 0 ? slope / expectedPeriod : 0
        let logRatio = slopeRatio > 0 ? abs(log(slopeRatio)) : 1.0
        // Hard cutoff at 10% deviation: harmonic confusion produces
        // slope ratios near 0.5 or 2.0; clean rate fits hold near 1.0.
        let rateConsistency = logRatio < 0.1 ? 1.0 : 0.0
        return confirmedFraction * q * sigmaPen * rateConsistency
    }
}
