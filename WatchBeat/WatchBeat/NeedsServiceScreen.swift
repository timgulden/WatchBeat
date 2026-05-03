import SwiftUI

struct NeedsServiceScreen: View {
    let data: MeasurementCoordinator.NeedsServiceData
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Watch needs service")
                        .font(.title3.bold())
                }
                .frame(maxWidth: .infinity, alignment: .center)

                VStack(spacing: 4) {
                    Text(rateErrorDisplay)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(severityColor)
                        .monospacedDigit()
                    Text("per day \(data.rateErrorSecondsPerDay >= 0 ? "fast" : "slow")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)

                HStack(spacing: 8) {
                    Text("Severity:")
                        .font(.subheadline.bold())
                    Text(severityLabel)
                        .font(.subheadline.bold())
                        .foregroundStyle(severityColor)
                }

                Text("Rate identified at \(data.rateBPH) bph, but running far outside the normal ±120 s/day range for a healthy mechanical watch. A cleaning, lubrication, or regulation is likely needed.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("For reference, a well-regulated modern mechanical watch runs within ±10 s/day; a typical vintage movement within ±60 s/day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)

            Spacer()

            ActionButton(title: "Try Again") {
                coordinator.startMonitoring()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watch needs service. Running \(Int(abs(data.rateErrorSecondsPerDay))) seconds per day \(data.rateErrorSecondsPerDay >= 0 ? "fast" : "slow") at \(data.rateBPH) beats per hour. Severity: \(severityLabel).")
    }

    private var rateErrorDisplay: String {
        let secs = Int(data.rateErrorSecondsPerDay.rounded())
        let sign = secs >= 0 ? "+" : ""
        return "\(sign)\(secs) s"
    }

    private var severityLabel: String {
        let abs = Swift.abs(data.rateErrorSecondsPerDay)
        if abs >= 5000 { return "Severe" }
        if abs >= 1000 { return "Significant" }
        return "Elevated"
    }

    private var severityColor: Color {
        let abs = Swift.abs(data.rateErrorSecondsPerDay)
        if abs >= 5000 { return .red }
        if abs >= 1000 { return .orange }
        return .yellow
    }
}
