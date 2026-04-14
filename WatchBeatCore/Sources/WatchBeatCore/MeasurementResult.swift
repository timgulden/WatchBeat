import Foundation

/// A single tick's timing data for the timegrapher plot.
public struct TickTiming: Sendable {
    /// Beat index (0, 1, 2, ...).
    public let beatIndex: Int
    /// Residual from regression line in milliseconds.
    public let residualMs: Double
    /// Whether this is an even beat (tick vs tock).
    public let isEvenBeat: Bool

    public init(beatIndex: Int, residualMs: Double, isEvenBeat: Bool) {
        self.beatIndex = beatIndex
        self.residualMs = residualMs
        self.isEvenBeat = isEvenBeat
    }
}

/// The output of the full measurement pipeline.
public struct MeasurementResult: Sendable {
    public let snappedRate: StandardBeatRate
    public let rateErrorSecondsPerDay: Double
    public let beatErrorMilliseconds: Double?
    public let amplitudeProxy: Double
    public let qualityScore: Double
    public let tickCount: Int
    /// Tick timing data for the timegrapher plot.
    public let tickTimings: [TickTiming]

    public init(
        snappedRate: StandardBeatRate,
        rateErrorSecondsPerDay: Double,
        beatErrorMilliseconds: Double?,
        amplitudeProxy: Double,
        qualityScore: Double,
        tickCount: Int,
        tickTimings: [TickTiming] = []
    ) {
        self.snappedRate = snappedRate
        self.rateErrorSecondsPerDay = rateErrorSecondsPerDay
        self.beatErrorMilliseconds = beatErrorMilliseconds
        self.amplitudeProxy = amplitudeProxy
        self.qualityScore = qualityScore
        self.tickCount = tickCount
        self.tickTimings = tickTimings
    }
}
