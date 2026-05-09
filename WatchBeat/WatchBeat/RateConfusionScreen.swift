import SwiftUI

/// Picker locked onto a rate that's >7% off the snapped standard. Could be a
/// partially-resolved harmonic, a non-tick periodic event in the recording,
/// or a watch genuinely running at a non-standard rate. Visually parallels
/// NeedsServiceScreen — same big-number layout, different color and message.
struct RateConfusionScreen: View {
    let data: MeasurementCoordinator.RateConfusionData
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.diamond")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Unexpected rate")
                        .font(.title3.bold())
                }
                .frame(maxWidth: .infinity, alignment: .center)

                VStack(spacing: 4) {
                    Text(String(format: "%.2f Hz", data.measuredOscHz))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                    Text("doesn't match a standard rate")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)

                Text("Closest standard: \(data.snappedRateBPH) bph (\(String(format: "%.2f", data.snappedRateOscHz)) Hz). The picker may have locked onto a harmonic or a non-tick event in the recording.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    tipRow(icon: "magnifyingglass", text: "If you know your watch's beat rate, check whether the measured value matches.")
                    tipRow(icon: "rotate.3d", text: "Try a different watch position.")
                    tipRow(icon: "iphone.gen3", text: "Press the phone firmly against the caseback.")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)

            Spacer()

            ActionButton(title: "Try Again") {
                coordinator.startMonitoring()
            }
            .padding(.horizontal, 20)
            HStack {
                Spacer()
                SendDebugButton(coordinator: coordinator)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unexpected rate. Measured \(String(format: "%.2f", data.measuredOscHz)) Hertz, which doesn't match a standard rate. Closest standard is \(data.snappedRateBPH) beats per hour.")
    }
}
