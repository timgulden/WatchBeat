import Foundation

/// Diagnostic data from each pipeline stage, for debugging real-world captures.
public struct PipelineDiagnostics: Sendable {
    /// Peak amplitude of the raw input signal.
    public let rawPeakAmplitude: Float
    /// Peak amplitude after bandpass filtering.
    public let filteredPeakAmplitude: Float
    /// Peak amplitude of the decimated envelope.
    public let envelopePeakAmplitude: Float
    /// The period estimate from autocorrelation (may differ from final rate).
    public let periodEstimate: PeriodEstimate
    /// Number of ticks found by the locator (before outlier rejection).
    public let tickCount: Int
    /// The envelope sample rate after decimation.
    public let envelopeSampleRate: Double
    /// The decimation factor used.
    public let decimationFactor: Int
}

/// Orchestrates the full DSP pipeline.
///
/// Uses a try-all-rates strategy: rather than trusting the period estimator alone
/// (which can fail at low SNR), the pipeline runs tick detection and regression
/// at each of the 7 standard beat rates and selects the rate that produces the
/// best regression fit. This is robust to noise because the correct rate will
/// produce regularly-spaced ticks with low residuals, while wrong rates produce
/// irregular spacing and high residuals.
public struct MeasurementPipeline {

    private let conditioner = SignalConditioner()
    private let periodEstimator = PeriodEstimator()
    private let tickLocator = TickLocator()
    private let rateAnalyzer = RateAnalyzer()

    public init() {}

    /// Run the full measurement pipeline on a raw audio buffer.
    public func measure(_ input: AudioBuffer) -> MeasurementResult {
        let (result, _) = measureWithDiagnostics(input)
        return result
    }

    /// Run the full pipeline and return both the result and diagnostic data.
    public func measureWithDiagnostics(_ input: AudioBuffer) -> (MeasurementResult, PipelineDiagnostics) {
        // Stage 1: Bandpass + envelope + decimate
        let conditioned = conditioner.process(input)

        // Stage 2: Estimate period from envelope (used as a hint and for diagnostics)
        let periodEstimate = periodEstimator.estimate(envelope: conditioned.envelope)

        // Stage 3: Try all standard beat rates.
        // For each rate, build a template, locate ticks, and analyze.
        // Score each by: number of ticks surviving outlier rejection * quality score.
        // The correct rate produces the most clean ticks with the best fit.
        var bestResult: MeasurementResult?
        var bestScore: Double = -1

        for rate in StandardBeatRate.allCases {
            // Create a synthetic period estimate for this candidate rate
            let candidateEstimate = PeriodEstimate(
                measuredHz: rate.hz,
                snappedRate: rate,
                confidence: periodEstimate.confidence
            )

            let templateBuilder = TemplateBuilder()
            let template = templateBuilder.build(filtered: conditioned.filtered, periodEstimate: candidateEstimate)
            let tickLocations = tickLocator.locate(filtered: conditioned.filtered, template: template, periodEstimate: candidateEstimate)

            // Need at least a few ticks to evaluate
            guard tickLocations.tickTimesSeconds.count >= 3 else { continue }

            let result = rateAnalyzer.analyze(tickLocations: tickLocations, periodEstimate: candidateEstimate)

            // Score: quality-weighted tick recovery rate.
            // Normalize tick count by expected count for this rate, so a 4 Hz rate
            // finding 100/120 expected ticks scores the same as an 8 Hz rate finding
            // 200/240. This prevents higher rates from winning just by having more
            // opportunities. Quality score dominates — a wrong rate may find ticks
            // but they'll have high residuals.
            let duration = Double(conditioned.filtered.samples.count) / conditioned.filtered.sampleRate
            let expectedTicks = duration * rate.hz
            let recoveryRate = min(1.0, Double(result.tickCount) / max(1.0, expectedTicks))
            let score = recoveryRate * (0.01 + result.qualityScore)

            if score > bestScore {
                bestScore = score
                bestResult = result
            }
        }

        let finalResult = bestResult ?? MeasurementResult(
            snappedRate: periodEstimate.snappedRate,
            rateErrorSecondsPerDay: 0,
            beatErrorMilliseconds: nil,
            amplitudeProxy: 0,
            qualityScore: 0,
            tickCount: 0
        )

        let diagnostics = PipelineDiagnostics(
            rawPeakAmplitude: input.samples.map { abs($0) }.max() ?? 0,
            filteredPeakAmplitude: conditioned.filtered.samples.map { abs($0) }.max() ?? 0,
            envelopePeakAmplitude: conditioned.envelope.samples.max() ?? 0,
            periodEstimate: periodEstimate,
            tickCount: finalResult.tickCount,
            envelopeSampleRate: conditioned.envelope.sampleRate,
            decimationFactor: conditioned.decimationFactor
        )

        return (finalResult, diagnostics)
    }
}
