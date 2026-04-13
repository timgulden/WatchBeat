import Foundation

/// Diagnostic data from each pipeline stage, for debugging real-world captures.
public struct PipelineDiagnostics: Sendable {
    /// Peak amplitude of the raw input signal.
    public let rawPeakAmplitude: Float
    /// Peak amplitude after bandpass filtering.
    public let filteredPeakAmplitude: Float
    /// Peak amplitude of the decimated envelope.
    public let envelopePeakAmplitude: Float
    /// The period estimate (rate, frequency, confidence).
    public let periodEstimate: PeriodEstimate
    /// Number of ticks found by the locator.
    public let tickCount: Int
    /// The envelope sample rate after decimation.
    public let envelopeSampleRate: Double
    /// The decimation factor used.
    public let decimationFactor: Int
}

/// Orchestrates the full DSP pipeline: condition -> estimate period -> build template
/// -> locate ticks -> analyze rate.
public struct MeasurementPipeline {

    private let conditioner = SignalConditioner()
    private let periodEstimator = PeriodEstimator()
    private let templateBuilder = TemplateBuilder()
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

        // Stage 2: Estimate period from envelope
        let periodEstimate = periodEstimator.estimate(envelope: conditioned.envelope)

        // Stage 3: Build averaged tick template from filtered signal
        let template = templateBuilder.build(filtered: conditioned.filtered, periodEstimate: periodEstimate)

        // Stage 4: Locate individual ticks
        let tickLocations = tickLocator.locate(filtered: conditioned.filtered, template: template, periodEstimate: periodEstimate)

        // Stage 5: Linear regression for rate error + diagnostics
        let result = rateAnalyzer.analyze(tickLocations: tickLocations, periodEstimate: periodEstimate)

        let diagnostics = PipelineDiagnostics(
            rawPeakAmplitude: input.samples.map { abs($0) }.max() ?? 0,
            filteredPeakAmplitude: conditioned.filtered.samples.map { abs($0) }.max() ?? 0,
            envelopePeakAmplitude: conditioned.envelope.samples.max() ?? 0,
            periodEstimate: periodEstimate,
            tickCount: tickLocations.tickTimesSeconds.count,
            envelopeSampleRate: conditioned.envelope.sampleRate,
            decimationFactor: conditioned.decimationFactor
        )

        return (result, diagnostics)
    }
}
