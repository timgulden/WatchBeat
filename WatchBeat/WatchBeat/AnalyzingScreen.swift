import SwiftUI

/// Brief "Success" pause shown after a successful recording, before
/// transitioning to the result screen. The spectrogram from the
/// recording session stays visible (frozen — the SpectrogramMonitor
/// has stopped feeding it) so the user has continuity between what
/// they saw during measurement and the result.
///
/// If a failure is being processed (Weak Signal, Low Confidence, etc.)
/// the spinner variant is shown instead — those cases are routed by
/// the coordinator and don't display through this screen, but the
/// generic "Analyzing…" fallback handles edge cases.
struct AnalyzingScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        SquareScreenLayout(rotation: coordinator.latchedUIRotation) {
            Color.clear
        } bigSquare: {
            VStack(spacing: 6) {
                SpectrogramView(data: coordinator.spectrogramData,
                                analysisWindowFraction: 1.0,
                                analysisTintColor: Color.green.opacity(0.20))
                    .frame(maxHeight: .infinity)
                Text("Success")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text(" ")  // reserves the same vertical space as the recording tip
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        } controls: {
            VStack(spacing: 10) {
                BottomRow()
            }
        }
    }
}
