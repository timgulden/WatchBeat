import SwiftUI

struct MonitoringScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = sweepElapsed()
            let ready = elapsed >= MeasurementConstants.listenSweepDuration
            SquareScreenLayout(rotation: coordinator.latchedUIRotation, bigOnTop: true) {
                // Lower (small/flexible) square: short instructional bullets.
                SimpleTipsBlock(title: "While listening…", tips: [
                    ("hand.raised", "Hold steady."),
                    ("ear", "Keep the environment quiet."),
                    ("play.circle", "Tap Measure when ready."),
                ])
            } bigSquare: {
                // Upper (big/fixed) square: spectrogram + status.
                SpectrogramSquare(
                    data: coordinator.spectrogramData,
                    status: "Listening…",
                    tintColor: Color.clear
                )
            } controls: {
                VStack(spacing: 10) {
                    ActionButton(title: "Measure") {
                        coordinator.startMeasurement()
                    }
                    .disabled(!ready)
                    BottomRow(cancelAction: { coordinator.stopMonitoring() })
                }
            }
        }
    }

    /// Seconds since monitoring began (for the Measure-button gate).
    private func sweepElapsed() -> Double {
        guard let start = coordinator.monitoringStartTime else { return 0 }
        return (ContinuousClock.now - start).asSeconds
    }
}

/// Square container holding the spectrogram with a status caption below.
/// Used in the big-square slot of MonitoringScreen / RecordingScreen /
/// AnalyzingScreen — the slot is already a fixed square so we just fill
/// it. Status text takes a fixed strip below the spectrogram.
struct SpectrogramSquare: View {
    @ObservedObject var data: SpectrogramData
    let status: String
    let tintColor: Color

    var body: some View {
        VStack(spacing: 4) {
            SpectrogramView(data: data, analysisTintColor: tintColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(status)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 22)
        }
        .padding(8)
    }
}

/// Compact instructional bullets used by the lower (flexible) square on
/// the live screens. Square-ish by virtue of .aspectRatio(1), so it
/// rotates cleanly with the rest of the layout during position studies.
struct SimpleTipsBlock: View {
    let title: String
    let tips: [(icon: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(0..<tips.count, id: \.self) { i in
                tipRow(icon: tips[i].icon, text: tips[i].text)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .aspectRatio(1, contentMode: .fit)
    }
}
