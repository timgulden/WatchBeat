import SwiftUI

struct MonitoringScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = sweepElapsed()
            let ready = elapsed >= MeasurementConstants.listenSweepDuration
            SquareScreenLayout(rotation: coordinator.latchedUIRotation) {
                // The wheel previously lived here; intentionally empty so the
                // spectrogram has more vertical room. Could become a brand
                // mark or signal-strength glyph later.
                Color.clear
            } bigSquare: {
                VStack(spacing: 6) {
                    SpectrogramView(data: coordinator.spectrogramData,
                                    analysisWindowFraction: 0)
                        .frame(maxHeight: .infinity)
                    Text("Listening…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("Hold the bottom of the phone against your watch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(8)
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
