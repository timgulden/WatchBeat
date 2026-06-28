import SwiftUI

struct RecordingScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = elapsedTime()
            let analysisFraction = min(elapsed / MeasurementConstants.analysisWindow, 1.0)
            let phase = currentPhase(elapsed: elapsed)

            SquareScreenLayout(rotation: coordinator.latchedUIRotation) {
                Color.clear  // wheel removed
            } bigSquare: {
                VStack(spacing: 6) {
                    SpectrogramView(
                        data: coordinator.spectrogramData,
                        analysisWindowFraction: analysisFraction,
                        analysisTintColor: phase.tintColor
                    )
                    .frame(maxHeight: .infinity)
                    Text(phase.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("Hold steady — measurement in progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(8)
            } controls: {
                VStack(spacing: 10) {
                    BottomRow(cancelAction: { coordinator.cancelMeasurement() })
                }
            }
        }
    }

    private struct Phase {
        let label: String
        let tintColor: Color
    }

    /// Three phases:
    /// - 0–15 s: "Measuring…" — pale yellow tint growing right→left
    /// - 15+ s with not yet auto-stopped: "Searching for signal…" —
    ///   orange tint (algorithm needs more time)
    /// - When session ends successfully we transition to a result screen,
    ///   so "Success" is shown by the coordinator's state transition, not
    ///   here.
    private func currentPhase(elapsed: Double) -> Phase {
        if elapsed < MeasurementConstants.analysisWindow {
            return Phase(label: "Measuring…", tintColor: Color.yellow.opacity(0.18))
        }
        return Phase(label: "Searching for signal…", tintColor: Color.orange.opacity(0.22))
    }

    private func elapsedTime() -> Double {
        guard let start = coordinator.recordingStartTime else { return 0 }
        return min((ContinuousClock.now - start).asSeconds, coordinator.maxRecordingTime)
    }
}
