import Foundation

/// Beat error estimation from regression residuals.
///
/// Beat error measures the tick/tock timing asymmetry of a mechanical
/// watch escapement. The pairwise-absolute formulation is used instead
/// of the simpler `|mean(even) - mean(odd)|` because it does not let
/// opposite-sign pair differences cancel: when some pairs drift
/// tick-before-tock and others drift tock-before-tick across the
/// recording (as on disorderly watches where tick and tock positions
/// trade places), the reported value reflects the average magnitude of
/// the asymmetry rather than averaging to zero.
///
/// For perfectly clean watches with zero true asymmetry, the reported
/// value is noise-floor-limited (≈ sd_residual × √(2/π)), typically
/// fractions of a millisecond — more honest than reporting "0 ms beat
/// error" when ticks naturally scatter by a millisecond or two. When
/// tick and tock wander in lock-step (correlated jitter) the difference
/// stays constant per pair and pair-abs reduces to the true offset.
enum BeatError {
    /// Mean of `|even_residual - adjacent_odd_residual|` over all
    /// consecutive (even, even+1) beat-index pairs present in the map.
    /// Residuals in seconds; returns seconds. Returns `nil` when no
    /// complete tick/tock pair is available.
    static func meanPairedAbsDifference(residualsByBeat: [Int: Double]) -> Double? {
        var absDiffs: [Double] = []
        for (beat, evenResidual) in residualsByBeat where beat % 2 == 0 {
            if let oddResidual = residualsByBeat[beat + 1] {
                absDiffs.append(abs(evenResidual - oddResidual))
            }
        }
        guard !absDiffs.isEmpty else { return nil }
        return absDiffs.reduce(0, +) / Double(absDiffs.count)
    }
}
