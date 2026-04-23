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
    /// Tick timings for the amplitude estimator. Usually identical to
    /// `tickTimings`, but in the harmonic-tiebreak path (36000→18000 swap)
    /// the display timings are at 2× rate (so the timegraph shows the
    /// clean main-vs-sub pattern) while amplitude needs timings at the
    /// reported rate's beatIndex spacing.
    public let amplitudeTickTimings: [TickTiming]

    public init(
        snappedRate: StandardBeatRate,
        rateErrorSecondsPerDay: Double,
        beatErrorMilliseconds: Double?,
        amplitudeProxy: Double,
        qualityScore: Double,
        tickCount: Int,
        tickTimings: [TickTiming] = [],
        amplitudeTickTimings: [TickTiming]? = nil
    ) {
        self.snappedRate = snappedRate
        self.rateErrorSecondsPerDay = rateErrorSecondsPerDay
        self.beatErrorMilliseconds = beatErrorMilliseconds
        self.amplitudeProxy = amplitudeProxy
        self.qualityScore = qualityScore
        self.tickCount = tickCount
        self.tickTimings = tickTimings
        self.amplitudeTickTimings = amplitudeTickTimings ?? tickTimings
    }
}
