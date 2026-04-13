import Foundation

/// The set of recognized standard watch beat rates.
public enum StandardBeatRate: Int, CaseIterable, Sendable {
    case bph3600 = 3600
    case bph14400 = 14400
    case bph18000 = 18000
    case bph21600 = 21600
    case bph25200 = 25200
    case bph28800 = 28800
    case bph36000 = 36000

    /// Beat frequency in Hz.
    public var hz: Double { Double(rawValue) / 3600.0 }

    /// Nominal period between beats in seconds.
    public var nominalPeriodSeconds: Double { 1.0 / hz }

    /// Whether this is a quartz rate (1 Hz stepper motor).
    public var isQuartz: Bool { self == .bph3600 }

    /// Find the nearest standard beat rate to a given frequency in Hz.
    public static func nearest(toHz frequency: Double) -> StandardBeatRate {
        allCases.min(by: { abs($0.hz - frequency) < abs($1.hz - frequency) })!
    }
}
