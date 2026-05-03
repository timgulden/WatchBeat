import Foundation

/// A folded-and-averaged tick template for cross-correlation.
struct TickTemplate: Sendable {
    /// The averaged template waveform, normalized to unit energy.
    let samples: [Float]
    /// The sample rate of the template (same as the raw signal).
    let sampleRate: Double
    /// Number of beats spanned: 2 for mechanical (tick+tock pair), 1 for quartz.
    let spansBeats: Int

    init(samples: [Float], sampleRate: Double, spansBeats: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.spansBeats = spansBeats
    }
}
