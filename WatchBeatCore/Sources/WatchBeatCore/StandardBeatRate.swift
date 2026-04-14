import Foundation

/// The set of recognized standard mechanical watch beat rates.
public enum StandardBeatRate: Int, CaseIterable, Sendable {
    case bph18000 = 18000
    case bph19800 = 19800
    case bph21600 = 21600
    case bph25200 = 25200
    case bph28800 = 28800
    case bph36000 = 36000

    /// Beat frequency — ticks per second. Used internally by DSP.
    /// (One oscillation = two beats, so this is 2× the oscillation frequency.)
    public var hz: Double { Double(rawValue) / 3600.0 }

    /// Oscillation frequency in Hz — the standard watch industry convention.
    /// 28800 bph = 4 Hz (4 oscillations/sec = 8 beats/sec).
    public var oscillationHz: Double { hz / 2.0 }

    /// Nominal period between beats in seconds.
    public var nominalPeriodSeconds: Double { 1.0 / hz }

    /// Whether this is a quartz rate. Always false for mechanical rates.
    public var isQuartz: Bool { false }

    /// Find the nearest standard beat rate to a given beat frequency (ticks/sec).
    public static func nearest(toHz frequency: Double) -> StandardBeatRate {
        allCases.min(by: { abs($0.hz - frequency) < abs($1.hz - frequency) })!
    }
}
