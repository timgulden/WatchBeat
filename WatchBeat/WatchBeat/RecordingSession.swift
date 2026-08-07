import Foundation
import WatchBeatCore

/// Manages the post-Measure analysis loop: waits for the audio buffer to
/// fill, then repeatedly pulls the most recent 15 s window, runs the
/// pipeline on it, scores the result, and tracks the best-scoring window
/// across the recording budget. Auto-stops as soon as it sees a fully-
/// trustworthy window (high quality, high confirmedFraction, not
/// low-confidence).
///
/// Owns no UI state. The coordinator wires `progressHandler` to its
/// `@Published` quality counters; everything else is internal.
///
/// Cancellation: the loop checks `Task.isCancelled` before every blocking
/// call, so cancelling the parent Task (e.g. via cancelMeasurement) ends
/// the loop cleanly without a final result.
struct RecordingSession {
    let captureService: AudioCaptureService
    let pipeline: BeatPicker
    let analysisWindow: Double
    let analysisInterval: Double
    let maxRecordingTime: Double
    /// Auto-stop threshold for raw qualityScore (the SNR-derived one). Set
    /// to MeasurementConstants.autoStopQuality by the caller.
    let qualityThreshold: Double
    /// When the user pressed Measure — drives the budget check.
    let startTime: ContinuousClock.Instant
    /// Called on each analysis pass with (currentDisplayedPercent,
    /// bestDisplayedPercentSoFar). Runs on the main actor so it can update
    /// the coordinator's @Published counters directly.
    let progressHandler: @MainActor (Int, Int) -> Void
    /// Optional acceptance gate called with each analysis window's end
    /// time. A window that fails is neither scored nor allowed to
    /// auto-stop. Position Study uses this to reject windows during which
    /// the phone left the target position; nil (normal measurements)
    /// accepts every window.
    var windowValidator: (@MainActor @Sendable (ContinuousClock.Instant) -> Bool)? = nil

    /// The single best-scoring window across the recording budget, or nil
    /// if the loop ended (cancelled / timed out) before any window completed.
    typealias BestWindow = (
        result: MeasurementResult,
        diagnostics: PipelineDiagnostics,
        buffer: WatchBeatCore.AudioBuffer,
        endTime: ContinuousClock.Instant
    )

    func run() async -> BestWindow? {
        // Phase 1: wait until the rolling buffer holds a full analysis
        // window. Capped by the overall recording budget so a stalled
        // capture doesn't hang here.
        while !Task.isCancelled {
            let elapsed = (ContinuousClock.now - startTime).asSeconds
            if elapsed > maxRecordingTime { break }
            let secs = await captureService.secondsCollected()
            if secs >= analysisWindow { break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Phase 2: analysis loop. Hard stop at exactly maxRecordingTime
        // (sleep is capped by remaining budget so we never overshoot).
        var best: BestWindow?
        var bestScore = -1.0
        var bestDisplayedPercent = 0

        while !Task.isCancelled {
            let elapsed = (ContinuousClock.now - startTime).asSeconds
            if elapsed > maxRecordingTime { break }

            if let buffer = await captureService.getRecentAudio(duration: analysisWindow) {
                // Stamp the window's end before the pipeline runs — the
                // pick takes long enough that "now" afterwards would let
                // post-window movement pollute the position check.
                let windowEnd = ContinuousClock.now

                if let validator = windowValidator {
                    let accepted = await MainActor.run { validator(windowEnd) }
                    if !accepted {
                        let remaining = maxRecordingTime - (ContinuousClock.now - startTime).asSeconds
                        try? await Task.sleep(for: .seconds(min(analysisInterval, max(0.05, remaining))))
                        continue
                    }
                }

                let (result, diagnostics) = await Task.detached { [pipeline] in
                    pipeline.pick(buffer)
                }.value

                let currentDisplayedPercent = MeasurementConstants.displayedQuality(result)
                bestDisplayedPercent = max(bestDisplayedPercent, currentDisplayedPercent)
                let snapshotCurrent = currentDisplayedPercent
                let snapshotBest = bestDisplayedPercent
                await MainActor.run {
                    progressHandler(snapshotCurrent, snapshotBest)
                }

                let s = score(result)
                if s > bestScore {
                    bestScore = s
                    // The window-end stamp lets the coordinator later ask
                    // the orientation monitor whether the phone stayed in
                    // one position across the window's 15-second span.
                    best = (result, diagnostics, buffer, windowEnd)
                }

                // Auto-stop only on a fully-trustworthy window: high quality,
                // confirmed (real ticks present), AND not low-confidence
                // (picker locked on them). A high-SNR result with high
                // jitter (lowConfidence) keeps the loop sliding the window
                // in case a better one emerges. Same for a high-SNR-but-
                // mostly-noise recording (low confirmedFraction).
                if result.qualityScore >= qualityThreshold
                    && result.confirmedFraction >= MeasurementConstants.autoStopConfirmedFraction
                    && !result.isLowConfidence {
                    break
                }
            }

            let remaining = maxRecordingTime - (ContinuousClock.now - startTime).asSeconds
            let sleepSec = min(analysisInterval, max(0.05, remaining))
            try? await Task.sleep(for: .seconds(sleepSec))
        }

        return best
    }

    /// Composite "best-window" trust score. Trust order:
    ///   confirmed AND non-lowConf  >  confirmed AND lowConf  >  unconfirmed
    /// Within the same trust class, prefer higher raw quality.
    private func score(_ r: MeasurementResult) -> Double {
        var s = r.qualityScore
        if r.confirmedFraction >= MeasurementConstants.bestWindowConfirmedTrustThreshold { s += 1.0 }
        if !r.isLowConfidence { s += 2.0 }
        return s
    }
}
