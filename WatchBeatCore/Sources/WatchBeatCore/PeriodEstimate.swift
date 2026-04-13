import Foundation

/// Result of FFT-based period estimation.
public struct PeriodEstimate: Sendable {
    /// The measured beat frequency in Hz (before snapping).
    public let measuredHz: Double
    /// The nearest standard beat rate.
    public let snappedRate: StandardBeatRate
    /// Confidence from FFT peak prominence, 0...1.
    public let confidence: Double

    public init(measuredHz: Double, snappedRate: StandardBeatRate, confidence: Double) {
        self.measuredHz = measuredHz
        self.snappedRate = snappedRate
        self.confidence = confidence
    }
}
