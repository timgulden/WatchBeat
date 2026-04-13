import Foundation

/// Shape of a synthetic tick waveform.
public enum TickShape: Sendable {
    /// Short exponentially-decaying burst around 5 kHz (~4 ms).
    case syntheticMechanical
    /// Softer, lower-frequency click typical of a quartz stepper motor.
    case syntheticQuartz
}

/// Parameters for generating a synthetic watch signal with known ground truth.
public struct SyntheticTickParameters: Sendable {
    public let beatRate: StandardBeatRate
    public let durationSeconds: Double
    public let sampleRate: Double
    public let rateErrorSecondsPerDay: Double
    public let beatErrorMilliseconds: Double
    public let jitterStdMicroseconds: Double
    public let snrDb: Double
    public let tickShape: TickShape
    public let seed: UInt64

    public init(
        beatRate: StandardBeatRate,
        durationSeconds: Double = 30.0,
        sampleRate: Double = 48000.0,
        rateErrorSecondsPerDay: Double = 0.0,
        beatErrorMilliseconds: Double = 0.0,
        jitterStdMicroseconds: Double = 0.0,
        snrDb: Double = 40.0,
        tickShape: TickShape = .syntheticMechanical,
        seed: UInt64 = 42
    ) {
        self.beatRate = beatRate
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.rateErrorSecondsPerDay = rateErrorSecondsPerDay
        self.beatErrorMilliseconds = beatErrorMilliseconds
        self.jitterStdMicroseconds = jitterStdMicroseconds
        self.snrDb = snrDb
        self.tickShape = tickShape
        self.seed = seed
    }
}

/// Generates synthetic watch audio signals for testing.
public struct SyntheticTickGenerator {

    public init() {}

    // TODO: Implement synthetic signal generation per spec section 7
}
