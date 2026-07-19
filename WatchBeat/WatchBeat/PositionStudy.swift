import Foundation

/// Progress and results of a guided five-position study. Value type held
/// by the coordinator (`@Published var study`) so every mutation publishes.
///
/// The position set is the watchmakers' standard five (COSC / ISO 3159):
/// the two horizontals plus the three verticals 6 Up, 3 Up, 9 Up. The
/// customarily-omitted sixth position is 12 Up (crown right), which
/// rarely occurs in wear.
struct PositionStudy: Equatable {

    enum Outcome: Equatable {
        case measured(MeasurementCoordinator.MeasurementDisplayData)
        case skipped
    }

    struct Reading: Equatable {
        let position: WatchPosition
        let outcome: Outcome
    }

    /// Study order: horizontals first, then verticals — the sequence
    /// timegrapher operators conventionally use. Dial Up first also means
    /// the study never auto-starts while the user is still reading the
    /// intro (they hold the phone upright at that point, which is Dial
    /// Down).
    static let positions: [WatchPosition] = [.dialUp, .dialDown, .sixUp, .crownUp, .crownDown]

    private(set) var readings: [Reading] = []

    /// Index of the position currently being measured. Retries don't
    /// append a reading, so the index only advances on success or skip.
    var currentIndex: Int { readings.count }

    /// The position to measure next, or nil when the study is complete.
    var target: WatchPosition? {
        currentIndex < Self.positions.count ? Self.positions[currentIndex] : nil
    }

    var isComplete: Bool { readings.count == Self.positions.count }

    mutating func record(_ outcome: Outcome) {
        guard let target else { return }
        readings.append(Reading(position: target, outcome: outcome))
    }

    // MARK: - Summary

    /// Successfully measured readings in study order.
    var measured: [(position: WatchPosition, data: MeasurementCoordinator.MeasurementDisplayData)] {
        readings.compactMap {
            if case .measured(let data) = $0.outcome { return ($0.position, data) }
            return nil
        }
    }

    /// Arithmetic mean of the positional rates — the standard "average
    /// daily rate" a positional study reports. Nil if nothing was measured.
    var meanRateError: Double? {
        let rates = measured.map(\.data.rateError)
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }

    /// Max − min positional rate — the positional-variation ("delta") spec
    /// quoted on movement datasheets. Nil unless at least two positions
    /// were measured.
    var rateDelta: Double? {
        let rates = measured.map(\.data.rateError)
        guard rates.count >= 2, let lo = rates.min(), let hi = rates.max() else { return nil }
        return hi - lo
    }
}
