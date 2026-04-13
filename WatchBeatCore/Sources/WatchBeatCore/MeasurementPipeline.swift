import Foundation

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
    ///
    /// - Parameter input: Raw audio from the microphone (or synthetic generator).
    /// - Returns: The measurement result with rate error, beat error, and quality metrics.
    public func measure(_ input: AudioBuffer) -> MeasurementResult {
        // Stage 1: Bandpass + envelope + decimate
        let conditioned = conditioner.process(input)

        // Stage 2: Estimate period from envelope
        let periodEstimate = periodEstimator.estimate(envelope: conditioned.envelope)

        // Stage 3: Build averaged tick template from filtered signal
        let template = templateBuilder.build(filtered: conditioned.filtered, periodEstimate: periodEstimate)

        // Stage 4: Locate individual ticks via cross-correlation
        let tickLocations = tickLocator.locate(filtered: conditioned.filtered, template: template, periodEstimate: periodEstimate)

        // Stage 5: Linear regression for rate error + diagnostics
        return rateAnalyzer.analyze(tickLocations: tickLocations, periodEstimate: periodEstimate)
    }
}
