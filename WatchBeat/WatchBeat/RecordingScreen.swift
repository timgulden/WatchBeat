import SwiftUI

struct RecordingScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = elapsedTime()
            let phase = currentPhase(elapsed: elapsed)
            SquareScreenLayout(rotation: coordinator.latchedUIRotation, bigOnTop: true) {
                SimpleTipsBlock(title: "While measuring…", tips: [
                    ("hand.raised", "Hold steady."),
                    ("ear", "Stay quiet."),
                    ("clock", "Most readings finish in 15 seconds."),
                ])
            } bigSquare: {
                SpectrogramSquare(
                    data: coordinator.spectrogramData,
                    status: phase.label,
                    tintColor: phase.tintColor
                )
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

    /// Status caption + tint color:
    /// - 0–15 s: "Measuring…" — pale yellow tint
    /// - 15+ s with no auto-stop yet: "Searching for signal…" — orange
    /// (When the session ends, MeasurementCoordinator transitions to
    /// AnalyzingScreen for the "Success" pause, then to a result page.)
    private func currentPhase(elapsed: Double) -> Phase {
        if elapsed < MeasurementConstants.analysisWindow {
            return Phase(label: "Measuring…", tintColor: Color.yellow.opacity(0.30))
        }
        return Phase(label: "Searching for signal…", tintColor: Color.orange.opacity(0.30))
    }

    private func elapsedTime() -> Double {
        guard let start = coordinator.recordingStartTime else { return 0 }
        return min((ContinuousClock.now - start).asSeconds, coordinator.maxRecordingTime)
    }
}
