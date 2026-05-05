import Foundation

/// A single tick's timing data for the timegrapher plot.
public struct TickTiming: Sendable, Equatable {
    /// Beat index (0, 1, 2, ...).
    public let beatIndex: Int
    /// Residual from regression line in milliseconds.
    public let residualMs: Double
    /// Whether this is an even beat (tick vs tock).
    public let isEvenBeat: Bool
    /// Absolute pick time in seconds from the start of the recording.
    /// Used by AmplitudeEstimator for per-class folding without re-anchoring.
    public let timeSeconds: Double

    public init(beatIndex: Int, residualMs: Double, isEvenBeat: Bool, timeSeconds: Double = 0) {
        self.beatIndex = beatIndex
        self.residualMs = residualMs
        self.isEvenBeat = isEvenBeat
        self.timeSeconds = timeSeconds
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
    /// True when the matched-filter trim had to drop too many ticks for
    /// a reliable measurement — the recording is acoustically complex
    /// enough (multiple comparable-amplitude sub-events, sub-event
    /// flipping, weak signal, etc.) that the picker couldn't lock on
    /// consistently. Note that the *watch* isn't disorderly — escapements
    /// are mechanically deterministic. This is a measurement-side flag
    /// indicating the analysis confidence is too low to display a result.
    /// The UI routes this to a "low confidence" retry screen rather than
    /// showing a number the user shouldn't trust.
    public let isLowConfidence: Bool

    /// Measured period (seconds per beat) from the regression. Combined
    /// with `regressionIntercept` and a tick's `beatIndex` + `residualMs`,
    /// the tick's absolute time in the recording is reconstructable as
    /// `measuredPeriod * beatIndex + regressionIntercept + residualMs/1000`.
    /// Exposed for diagnostic tools that need to overlay ticks on the
    /// audio timeline. Production code reads this only via the derived
    /// `rateErrorSecondsPerDay`.
    public let measuredPeriod: Double?

    /// Regression intercept (seconds). See `measuredPeriod`.
    public let regressionIntercept: Double?

    /// Fraction of analysis windows whose acoustic peak rose above
    /// background noise (per-window peak energy ÷ per-window gap energy
    /// > a threshold). Distinguishes "we couldn't hear a watch ticking
    /// in this recording" (low value → routes to Weak Signal) from
    /// "we heard ticks but their timing was erratic" (high value with
    /// high σ → routes to Low Analytical Confidence). Default 1.0
    /// (assume all confirmed) for callers that don't compute it.
    public let confirmedFraction: Double

    /// True when the envelope FFT shows a strong peak at ~1 Hz dominating
    /// all standard mechanical-rate bands. Quartz watches tick at exactly
    /// 1 Hz; if the recording's strongest periodic content sits there, the
    /// watch is quartz and WatchBeat can't analyze it (the app is designed
    /// for mechanical movements at 5-10 Hz). The router uses this to
    /// surface a clear "this is a quartz watch" page instead of a
    /// confusing weak-signal failure.
    public let quartzDetected: Bool

    public init(
        snappedRate: StandardBeatRate,
        rateErrorSecondsPerDay: Double,
        beatErrorMilliseconds: Double?,
        amplitudeProxy: Double,
        qualityScore: Double,
        tickCount: Int,
        tickTimings: [TickTiming] = [],
        amplitudeTickTimings: [TickTiming]? = nil,
        isLowConfidence: Bool = false,
        measuredPeriod: Double? = nil,
        regressionIntercept: Double? = nil,
        confirmedFraction: Double = 1.0,
        quartzDetected: Bool = false
    ) {
        self.snappedRate = snappedRate
        self.rateErrorSecondsPerDay = rateErrorSecondsPerDay
        self.beatErrorMilliseconds = beatErrorMilliseconds
        self.amplitudeProxy = amplitudeProxy
        self.qualityScore = qualityScore
        self.tickCount = tickCount
        self.tickTimings = tickTimings
        self.amplitudeTickTimings = amplitudeTickTimings ?? tickTimings
        self.isLowConfidence = isLowConfidence
        self.measuredPeriod = measuredPeriod
        self.regressionIntercept = regressionIntercept
        self.confirmedFraction = confirmedFraction
        self.quartzDetected = quartzDetected
    }
}
