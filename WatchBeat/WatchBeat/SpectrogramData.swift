import Foundation
import Combine

/// Rolling spectrogram state for the Monitoring/Recording UI.
///
/// Holds the most-recent 15-second window of STFT magnitude data as a
/// fixed-length circular column buffer. Each column is one short-time
/// FFT magnitude vector covering the 4-22 kHz band, normalized for
/// display.
///
/// Also tracks the best-band frequency the algorithm is currently
/// locked onto (for the red line overlay).
///
/// Updates are pushed from `SpectrogramMonitor` on a background queue
/// and consumed on the main thread by `SpectrogramView`. Marked
/// `@unchecked Sendable` because mutation is serialized through the
/// monitor's analysis queue; reads on the main thread tolerate a
/// momentarily-stale snapshot (worst case: one frame).
final class SpectrogramData: ObservableObject, @unchecked Sendable {
    /// Number of columns in the visible 15 s window. 300 × 50 ms = 15 s.
    static let columnCount = 300

    /// Number of frequency bins per column. 150 bins across 4-22 kHz
    /// gives ~120 Hz per bin — plenty of detail for visual identification
    /// of tick energy. SpectrogramView's bitmap renderer scales the
    /// 300 × 150 pixel grid to the display size with interpolation, so
    /// the visible output is smooth.
    static let binCount = 150

    /// Y-axis range shown on the display (Hz).
    static let minFreqHz: Double = 4000
    static let maxFreqHz: Double = 22000

    /// Time per column (seconds) — chosen so columnCount × columnDt = 15 s.
    static let columnDtSec: Double = 15.0 / Double(columnCount)

    /// Circular buffer of magnitude columns. `columns[writeIndex]` is the
    /// oldest column (about to be overwritten); columns wrap around.
    /// Each column is `binCount` log-magnitude values, scaled to [0, 1]
    /// for display (0 = silent black, 1 = full-energy white).
    @Published private(set) var columns: [[Float]]
    @Published private(set) var writeIndex: Int = 0

    /// Best-band frequency in Hz; nil while analysis hasn't yet locked
    /// on. UI renders a red horizontal line at this frequency.
    @Published var bestBandHz: Double? = nil

    /// Number of distinct columns ever written. Used by the UI to know
    /// how much of the 15 s window has actually been populated (the
    /// rest stays blank).
    @Published private(set) var totalColumnsWritten: Int = 0

    /// Absolute column index at which the current recording's analysis
    /// window began. Nil while not recording. The UI uses this to render
    /// the yellow analysis-window tint attached to specific columns —
    /// every column with absoluteIndex ≥ this value is "in the analysis
    /// window" and gets tinted. As the spectrogram scrolls left, the
    /// tint scrolls with it (same discrete-jump rate), so the visual
    /// representation of "this audio is being analyzed" stays bound to
    /// the actual audio.
    @Published var recordingStartColumnIndex: Int? = nil

    /// Fraction (0..1) of the visible 15 s window currently covered by
    /// the recording's analysis tint. Derived from
    /// `recordingStartColumnIndex` and `totalColumnsWritten` so the tint
    /// advances in exact lockstep with the spectrogram itself — one
    /// 1/columnCount step every time a new column is appended.
    var analysisWindowFraction: Double {
        guard let start = recordingStartColumnIndex else { return 0 }
        let elapsedColumns = max(0, totalColumnsWritten - start)
        return min(1.0, Double(elapsedColumns) / Double(Self.columnCount))
    }

    init() {
        columns = Array(repeating: [Float](repeating: 0, count: Self.binCount),
                        count: Self.columnCount)
    }

    /// Append a new column on the right edge. Called from the analysis
    /// queue at the monitor's column-emit rate; dispatches publishing
    /// to the main actor.
    ///
    /// All state mutation happens INSIDE the @MainActor Task — the
    /// previous implementation read writeIndex / totalColumnsWritten off
    /// the analysis thread before dispatching, which raced with other
    /// pending Tasks: multiple emits would read the same stale state
    /// and overwrite each other, losing both column data AND counter
    /// increments. The visible result was the column counter advancing
    /// slower than the actual emit rate (e.g., 9 Hz instead of 13 Hz),
    /// which made the column-tied analysis tint reach the left edge
    /// well after the 15-second wall-clock mark.
    func appendColumn(_ column: [Float]) {
        // Capture `column` immutably; let MainActor own all the state.
        Task { @MainActor in
            guard column.count == Self.binCount else { return }
            self.columns[self.writeIndex] = column
            self.writeIndex = (self.writeIndex + 1) % Self.columnCount
            self.totalColumnsWritten += 1
        }
    }

    /// Reset all data. Called when entering a fresh listening session
    /// (e.g., the user lands on the Monitoring screen).
    func reset() {
        let cleared = Array(repeating: [Float](repeating: 0, count: Self.binCount),
                            count: Self.columnCount)
        Task { @MainActor in
            self.columns = cleared
            self.writeIndex = 0
            self.bestBandHz = nil
            self.totalColumnsWritten = 0
            self.recordingStartColumnIndex = nil
        }
    }

    /// Mark the moment recording analysis begins. The next column to be
    /// written becomes the first "in-analysis-window" column; the tint
    /// will grow as further columns are added.
    @MainActor
    func markRecordingStart() {
        recordingStartColumnIndex = totalColumnsWritten
    }

    /// Clear the recording marker. Called when leaving the recording
    /// state so the tint disappears.
    @MainActor
    func markRecordingEnd() {
        recordingStartColumnIndex = nil
    }
}
