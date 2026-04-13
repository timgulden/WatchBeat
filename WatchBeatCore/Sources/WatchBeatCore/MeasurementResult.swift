import Foundation

/// The output of the full measurement pipeline.
public struct MeasurementResult: Sendable {
    /// The detected standard beat rate.
    public let snappedRate: StandardBeatRate
    /// Rate error in seconds per day. Positive = watch runs fast.
    public let rateErrorSecondsPerDay: Double
    /// Beat error (tick/tock asymmetry) in milliseconds. Nil for quartz.
    public let beatErrorMilliseconds: Double?
    /// Relative amplitude indicator from correlation peak magnitudes.
    public let amplitudeProxy: Double
    /// Measurement quality from regression residuals, 0...1.
    public let qualityScore: Double
    /// Number of ticks detected.
    public let tickCount: Int

    public init(
        snappedRate: StandardBeatRate,
        rateErrorSecondsPerDay: Double,
        beatErrorMilliseconds: Double?,
        amplitudeProxy: Double,
        qualityScore: Double,
        tickCount: Int
    ) {
        self.snappedRate = snappedRate
        self.rateErrorSecondsPerDay = rateErrorSecondsPerDay
        self.beatErrorMilliseconds = beatErrorMilliseconds
        self.amplitudeProxy = amplitudeProxy
        self.qualityScore = qualityScore
        self.tickCount = tickCount
    }
}
