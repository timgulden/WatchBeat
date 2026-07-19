import SwiftUI
import WatchBeatCore

/// Position Study summary. The dial shows the mean positional rate — the
/// standard "average daily rate" a positional study reports — with the
/// positional delta (max − min rate) beneath it. The per-position table
/// replaces the timegraph: rate, beat error, and amplitude for each of
/// the five positions. Beat error and amplitude are deliberately not
/// averaged; watchmaking practice reports those per position.
struct StudyResultScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    private var study: PositionStudy { coordinator.study ?? PositionStudy() }

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)
                .padding(.bottom, 4)

            VStack(spacing: 2) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Position Study")
                            .font(.subheadline.bold())
                        if let bph = commonRateBPH {
                            Text("\(bph) bph")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(study.measured.count) of \(PositionStudy.positions.count)")
                            .font(.subheadline.bold())
                        Text("Positions Measured")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                if let mean = study.meanRateError {
                    RateDialView(rateError: mean, beatErrorMs: nil)
                        .frame(maxHeight: 260)
                        .padding(.top, -8)
                        .accessibilityLabel("Average rate across positions")

                    VStack(spacing: 2) {
                        Text("Average of \(study.measured.count) positions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let delta = study.rateDelta {
                            Text("Δ \(Int(delta.rounded())) s/day between positions")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.top, -6)
                } else {
                    Spacer(minLength: 20)
                    Text("No positions were measured.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                positionTable

                Spacer(minLength: 8)

                ActionButton(title: "Done") {
                    coordinator.finishStudy()
                }
                .padding(.bottom, 20)
            }
            .padding(.horizontal, 20)
        }
    }

    /// The bph shared by every measured position, or nil if they disagree
    /// (a disagreement would itself be suspicious, so we just omit it).
    private var commonRateBPH: Int? {
        let rates = Set(study.measured.map(\.data.rateBPH))
        return rates.count == 1 ? rates.first : nil
    }

    // MARK: - Table

    private var positionTable: some View {
        VStack(spacing: 0) {
            tableRow(name: "", rate: "Rate", beat: "Beat Err", amp: "Amplitude", isHeader: true)
            Divider()
            ForEach(study.readings.indices, id: \.self) { i in
                let reading = study.readings[i]
                switch reading.outcome {
                case .measured(let data):
                    tableRow(name: reading.position.displayName,
                             rate: formatRate(data.rateError),
                             beat: data.beatErrorMs.map { String(format: "%.1f ms", $0) } ?? "—",
                             amp: amplitude(for: data).map { "\(Int($0))°" } ?? "—")
                case .skipped:
                    tableRow(name: reading.position.displayName,
                             rate: "—", beat: "—", amp: "—", dimmed: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func tableRow(name: String, rate: String, beat: String, amp: String,
                          isHeader: Bool = false, dimmed: Bool = false) -> some View {
        HStack {
            Text(name)
                .font(.subheadline.weight(isHeader ? .regular : .semibold))
                .frame(width: 86, alignment: .leading)
            Spacer()
            Text(rate)
                .frame(width: 88, alignment: .trailing)
            Text(beat)
                .frame(width: 66, alignment: .trailing)
            Text(amp)
                .frame(width: 66, alignment: .trailing)
        }
        .font(isHeader ? .caption : .subheadline.monospacedDigit())
        .foregroundStyle(isHeader || dimmed ? Color.secondary : Color.primary)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func formatRate(_ rateError: Double) -> String {
        let sign = rateError >= 0 ? "+" : ""
        return "\(sign)\(Int(rateError.rounded())) s/day"
    }

    /// Amplitude from the reading's stored pulse widths and the current
    /// lift angle — same computation the single-measurement Result screen
    /// uses.
    private func amplitude(for data: MeasurementCoordinator.MeasurementDisplayData) -> Double? {
        guard let pw = data.pulseWidths else { return nil }
        return AmplitudeEstimator.combinedAmplitude(
            pulseWidths: pw,
            beatRate: StandardBeatRate.nearest(toHz: Double(data.rateBPH) / 3600.0),
            rateErrorSecondsPerDay: data.rateError,
            liftAngleDegrees: coordinator.liftAngleDegrees
        )
    }
}
