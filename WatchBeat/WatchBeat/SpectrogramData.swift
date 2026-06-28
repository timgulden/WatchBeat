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
    /// Number of columns in the visible 15 s window. With 50 ms per
    /// column, 300 columns = exactly 15 s.
    static let columnCount = 300

    /// Number of frequency bins per column. STFT with 1024-pt FFT at
    /// 48 kHz gives 47 Hz/bin; 4-22 kHz spans ~380 bins.
    static let binCount = 380

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

    init() {
        columns = Array(repeating: [Float](repeating: 0, count: Self.binCount),
                        count: Self.columnCount)
    }

    /// Append a new column on the right edge. Called from the analysis
    /// queue at the monitor's column-emit rate; dispatches publishing
    /// to the main actor.
    func appendColumn(_ column: [Float]) {
        let idx = writeIndex
        var newColumns = columns
        if column.count == Self.binCount {
            newColumns[idx] = column
        }
        let newIdx = (idx + 1) % Self.columnCount
        let newTotal = totalColumnsWritten + 1
        Task { @MainActor in
            self.columns = newColumns
            self.writeIndex = newIdx
            self.totalColumnsWritten = newTotal
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
        }
    }
}
