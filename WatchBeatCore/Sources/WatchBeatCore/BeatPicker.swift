import Foundation

/// Abstraction over a single-call "give me a result" beat picker. Lets the
/// iOS coordinator (and tests) treat the pipeline as an opaque component
/// they configure once at init and call from the recording loop.
///
/// The default production conformance is `MeasurementPipeline` via the
/// Reference picker (the iOS app's chosen path). Tests can stub a mock
/// that returns canned `(MeasurementResult, PipelineDiagnostics)` pairs
/// to verify routing/recording-loop behavior in isolation.
public protocol BeatPicker: Sendable {
    /// Analyze a recorded audio buffer. Returns the measurement plus
    /// diagnostic info the coordinator may include in support strings.
    func pick(_ input: AudioBuffer) -> (MeasurementResult, PipelineDiagnostics)
}

extension MeasurementPipeline: BeatPicker {
    /// Default production behavior: use the Reference picker
    /// (matches the iOS app's existing call site).
    public func pick(_ input: AudioBuffer) -> (MeasurementResult, PipelineDiagnostics) {
        measureReferenceWithDiagnostics(input)
    }
}

/// Abstraction over the amplitude-estimator stage. Exposes the single
/// method the coordinator needs (measurePulseWidths). Tests can stub a
/// fixed PulseWidthEstimate.
public protocol AmplitudeMeasuring: Sendable {
    func measurePulseWidths(
        input: AudioBuffer,
        rate: StandardBeatRate,
        rateErrorSecondsPerDay: Double,
        tickTimings: [TickTiming]
    ) -> PulseWidthEstimate
}

extension AmplitudeEstimator: AmplitudeMeasuring {}
