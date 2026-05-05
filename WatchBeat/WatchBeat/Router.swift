import Foundation
import WatchBeatCore

/// Pure classification of a recording's outcome into one of the five
/// terminal pages. No side effects, no async work — the coordinator
/// interprets the decision and performs the state transition (and any
/// associated work like computing pulse widths or saving raw audio).
///
/// The four gates are evaluated in order:
///   1. Weak Signal       — not enough meaningful ticks
///   2. Low Confidence    — ticks present but timing erratic
///   3. Rate Confusion    — picker locked onto an off-grid rate
///   4. Needs Service     — rate plausible but watch is far gone
///   5. Display Result    — everything passed
enum Router {
    enum Decision: Equatable {
        case weakSignal(diagnostic: String)
        case lowAnalyticalConfidence
        case rateConfusion(MeasurementCoordinator.RateConfusionData)
        case needsService(MeasurementCoordinator.NeedsServiceData)
        /// All gates passed. Caller computes pulse widths and builds the
        /// display data from `bestResult` (which is non-nil in this case).
        case displayResult
    }

    /// Inputs needed to render the weak-signal diagnostic string. The
    /// Router builds the string itself when it routes to weakSignal —
    /// keeping the formatting in one place.
    struct WeakSignalContext {
        let sampleRate: Int
        let micConfig: String
    }

    /// Classify the recording. `bestResult` and `diagnostics` are nil if
    /// the recording loop produced no usable window (cancelled or timed
    /// out before any analysis completed) — that path also routes to
    /// weakSignal.
    static func classify(
        bestResult: MeasurementResult?,
        diagnostics: PipelineDiagnostics?,
        weakSignalContext: WeakSignalContext,
        maxPlausibleRateError: Double
    ) -> Decision {
        // Gate 1: Weak Signal. Either no result at all, or not enough
        // meaningful ticks to analyze. Use raw quality (display quality is
        // cosmetic only, see CLAUDE.md UI/UX principle 5).
        //
        // tickTimings.count is checked only when beatErrorMilliseconds is
        // not nil. A nil beatError indicates the pipeline INTENTIONALLY
        // suppressed per-tick output — either via the high-σ fallback
        // (rate is good, individual ticks too scattered to display) or
        // the harmonic tiebreak (rate report at the parent rate, ticks
        // belong to the harmonic). In both cases an empty tickTimings
        // is by design, not weak signal — quality and confirmedFraction
        // alone determine whether there's a real watch.
        let suppressedTicks = bestResult?.beatErrorMilliseconds == nil
        guard let result = bestResult,
              let diagnostics = diagnostics,
              result.qualityScore >= MeasurementConstants.minimumDisplayQuality,
              result.confirmedFraction >= MeasurementConstants.weakSignalMinConfirmedFraction,
              suppressedTicks || result.tickTimings.count >= MeasurementConstants.weakSignalMinTickCount else {
            let q = Int((bestResult?.qualityScore ?? 0) * 100)
            let cf = Int((bestResult?.confirmedFraction ?? 0) * 100)
            let peak = String(format: "%.3f", diagnostics?.rawPeakAmplitude ?? 0)
            let diag = "q=\(q)% confirmed=\(cf)% sr=\(weakSignalContext.sampleRate)Hz peak=\(peak) mic=\(weakSignalContext.micConfig)"
            return .weakSignal(diagnostic: diag)
        }

        // Gate 2: Low Analytical Confidence. Ticks ARE present
        // (confirmedFraction and tickTimings.count passed Gate 1), but
        // their timing is so erratic the picker can't lock — near-stall
        // watch territory.
        if result.isLowConfidence {
            return .lowAnalyticalConfidence
        }

        // Gate 3: Rate Confusion. The regression's measured rate disagrees
        // sharply with the chosen standard rate. Adjacent standard rates
        // differ by 10-20%, so a >7% mismatch means we locked onto a
        // non-standard rate (harmonic or non-tick event).
        let measuredOscHz = diagnostics.periodEstimate.measuredHz / 2.0
        let snappedOscHz = result.snappedRate.oscillationHz
        if abs(measuredOscHz - snappedOscHz) / snappedOscHz > MeasurementConstants.snapConfusionMaxFractionalDeviation {
            return .rateConfusion(MeasurementCoordinator.RateConfusionData(
                measuredOscHz: measuredOscHz,
                snappedRateBPH: result.snappedRate.rawValue,
                snappedRateOscHz: snappedOscHz
            ))
        }

        // Gate 4: Needs Service. Picker is solid, rate is real, watch is
        // just far outside the normal ±120 s/day band.
        if abs(result.rateErrorSecondsPerDay) > maxPlausibleRateError {
            return .needsService(MeasurementCoordinator.NeedsServiceData(
                rateBPH: result.snappedRate.rawValue,
                rateErrorSecondsPerDay: result.rateErrorSecondsPerDay
            ))
        }

        // Gate 5: success.
        return .displayResult
    }
}
