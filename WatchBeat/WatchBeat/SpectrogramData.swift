import Foundation
import Combine
import WatchBeatCore

/// Live data backing the Listen screen's two visualizations:
///
/// 1. **Band-energy trace** — a rolling 15-second time series of acoustic
///    energy at the algorithm's current best-band frequency (or broadband
///    if no band has been confidently selected yet). Renders as an
///    EKG-style line plot. Each tick of the watch shows up as a visible
///    spike.
///
/// 2. **Standard-rate bars** — Goertzel magnitudes at each of the six
///    standard mechanical beat rates (5, 5.5, 6, 7, 8, 10 Hz), computed
///    from the trace. The bar at the actual beat rate stands out;
///    diffuse bars mean no rhythm has been detected.
///
/// Both visualizations share the same source — the trace samples — so
/// the user sees consistent information. When the algorithm finds a
/// confident best band, the trace narrows to that band and the bars
/// sharpen.
final class SpectrogramData: ObservableObject, @unchecked Sendable {
    /// Number of trace samples in the visible 15 s window. 1500 × 10 ms.
    ///
    /// 10 ms bins matter: at the previous 50 ms (20 Hz) resolution, a
    /// 6 Hz tick train landed every 3⅓ bins, producing a visible moiré —
    /// displayed tick spacing alternated 150/200 ms and drifted with the
    /// tick-vs-bin phase, and ticks straddling a bin boundary split
    /// their energy and disappeared. At 100 Hz there are ~16 bins per
    /// beat and the structure renders faithfully.
    static let traceSampleCount = 1500

    /// Seconds per trace sample (10 ms).
    static let traceDtSec: Double = 15.0 / Double(traceSampleCount)

    /// Rolling 15-second buffer of best-band energy. Circular.
    @Published private(set) var trace: [Float]

    /// Next index to write in the circular trace buffer.
    @Published private(set) var traceWriteIndex: Int = 0

    /// Monotonic counter — total trace samples ever written. The UI
    /// uses this both to decide "how much of the window has been
    /// populated" and to drive the analysis-window fraction (when
    /// recording is active).
    @Published private(set) var totalTraceWritten: Int = 0

    /// Magnitude at each standard beat rate, normalized to [0, 1] within
    /// the current snapshot (the strongest rate is always at 1.0). Drives
    /// the bar heights. Empty until we have ≥ 2 s of trace data.
    @Published var rateMagnitudes: [StandardBeatRate: Float] = [:]

    /// Best-band center frequency in Hz. Shown as a small label under
    /// the bars. Initial value matches the SpectrogramMonitor seed band
    /// (18 kHz) so the label never has to fall back to "Scanning…" —
    /// even before the first real band-selection scan runs, this is the
    /// band the trace and bars are actually using.
    @Published var bestBandHz: Double = 18000.0

    /// Absolute trace-sample index at which the current recording's
    /// analysis window began. Currently unused by the visible UI (we
    /// dropped the yellow tint), but kept for future use if we need to
    /// visualize which audio is being analyzed.
    @Published var recordingStartIndex: Int? = nil

    init() {
        trace = [Float](repeating: 0, count: Self.traceSampleCount)
    }

    /// Append a batch of trace samples on the right edge. Called from
    /// the analysis queue every ~50 ms with five 10 ms samples — batching
    /// keeps the UI-update rate at ~20 Hz even though the trace's
    /// temporal resolution is 100 Hz. All state mutation happens inside
    /// the @MainActor Task body to avoid the data race that previously
    /// dropped updates (analysis thread reading stale @Published state,
    /// multiple tasks overwriting each other).
    func appendTraceSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        Task { @MainActor in
            for sample in samples {
                self.trace[self.traceWriteIndex] = sample
                self.traceWriteIndex = (self.traceWriteIndex + 1) % Self.traceSampleCount
                self.totalTraceWritten += 1
            }
        }
    }

    /// Publish a new snapshot of rate-bar magnitudes. Caller (monitor)
    /// supplies a dict of magnitudes that are already normalized to
    /// [0, 1] with the strongest at 1.0.
    func publishRateMagnitudes(_ mags: [StandardBeatRate: Float]) {
        Task { @MainActor in
            self.rateMagnitudes = mags
        }
    }

    /// Reset all data. Called when entering a fresh Listen session.
    /// `bestBandHz` is NOT cleared — SpectrogramMonitor.resetState
    /// republishes it on every Listen start anyway, and clearing it
    /// here would create a brief "Scanning…" flash between sessions.
    func reset() {
        let cleared = [Float](repeating: 0, count: Self.traceSampleCount)
        Task { @MainActor in
            self.trace = cleared
            self.traceWriteIndex = 0
            self.totalTraceWritten = 0
            self.rateMagnitudes = [:]
            self.recordingStartIndex = nil
        }
    }

    /// Mark the moment the picker's analysis window begins (kept for
    /// future use; current UI doesn't visualize it).
    @MainActor
    func markRecordingStart() {
        recordingStartIndex = totalTraceWritten
    }

    @MainActor
    func markRecordingEnd() {
        recordingStartIndex = nil
    }

    /// Visible-trace samples in order (oldest to newest), padded with
    /// zeros on the left if fewer than traceSampleCount samples have
    /// been written. Used by the UI for rendering.
    func visibleTrace() -> [Float] {
        let total = totalTraceWritten
        let count = Self.traceSampleCount
        if total >= count {
            // Buffer wrapped — start at writeIndex.
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                out[i] = trace[(traceWriteIndex + i) % count]
            }
            return out
        } else {
            // Partial fill — pad left with zeros so newest is at right edge.
            var out = [Float](repeating: 0, count: count)
            let pad = count - total
            for i in 0..<total {
                out[pad + i] = trace[i]
            }
            return out
        }
    }

    /// Replace the trace samples with a fresh re-interpretation of the
    /// same audio (typically because the best-band selector has switched
    /// to a different frequency band). Two cases:
    ///
    /// • **Partial fill** (totalTraceWritten < traceSampleCount, i.e.,
    ///   we're still in the left-to-right "growing" phase): write the
    ///   rebuild samples into trace[0..k] and leave writeIndex /
    ///   totalTraceWritten unchanged. Subsequent emits continue
    ///   appending at writeIndex as before, so the growing-from-left
    ///   visual continues uninterrupted — only the trace's SHAPE
    ///   changes (now reinterpreted through the new band).
    ///
    /// • **Full buffer** (already wrapped): place the rebuild samples
    ///   in linear order across the whole buffer (oldest at index 0,
    ///   newest at n-1) and reset writeIndex to 0. The scrolling
    ///   behavior continues from there.
    @MainActor
    func replaceTrace(with newSamples: [Float]) {
        let n = Self.traceSampleCount
        let k = min(newSamples.count, n)
        let startInNew = newSamples.count - k

        if totalTraceWritten < n {
            // Partial fill: overwrite trace[0..k] with the new-band
            // interpretation. Don't touch writeIndex / totalTraceWritten —
            // any post-snapshot samples that have arrived (positions
            // trace[k..writeIndex]) were already computed under the new
            // band and stay valid.
            for i in 0..<k { trace[i] = newSamples[startInNew + i] }
        } else {
            // Full buffer: linear layout, scrolling mode.
            for i in 0..<(n - k) { trace[i] = 0 }
            for i in 0..<k { trace[n - k + i] = newSamples[startInNew + i] }
            traceWriteIndex = 0
        }
    }
}
