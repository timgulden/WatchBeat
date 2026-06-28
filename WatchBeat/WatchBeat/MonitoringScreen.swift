import SwiftUI

struct MonitoringScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = sweepElapsed()
            let ready = elapsed >= MeasurementConstants.listenSweepDuration
            SquareScreenLayout(rotation: coordinator.latchedUIRotation) {
                // Upper square: spectrogram + status, constrained square
                // so it rotates cleanly when the phone changes pose.
                SpectrogramSquare(
                    data: coordinator.spectrogramData,
                    status: "Listening…",
                    tintColor: Color.clear
                )
            } bigSquare: {
                // Lower square: instructions.
                VStack(alignment: .leading, spacing: 12) {
                    Text("While listening…")
                        .font(.headline)
                        .padding(.bottom, 4)
                    tipRow(icon: "hand.raised", text: "Hold steady.")
                    tipRow(icon: "ear", text: "Keep the environment quiet.")
                    tipRow(icon: "play.circle", text: "Tap Measure when ready.")
                    Spacer()
                }
                .padding(16)
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
/// Used by Monitoring, Recording, and Analyzing in their smallSquare
/// slot — `.aspectRatio(1)` keeps the bounding box invariant under 90°
/// rotation so the SquareScreenLayout's rotation behavior works cleanly.
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
        .aspectRatio(1, contentMode: .fit)
    }
}
