import SwiftUI

/// Brief "Success" pause after a successful recording, before the
/// result page appears. The spectrogram from the recording session
/// stays visible (the SpectrogramMonitor has stopped feeding it so
/// the columns are frozen) with a green analysis-window tint so the
/// user has visual continuity between measurement and result.
struct AnalyzingScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        SquareScreenLayout(rotation: coordinator.latchedUIRotation) {
            SpectrogramSquare(
                data: coordinator.spectrogramData,
                status: "Success",
                tintColor: Color.green.opacity(0.25)
            )
        } bigSquare: {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Reading captured")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 40)
        } controls: {
            VStack(spacing: 10) {
                BottomRow()
            }
        }
    }
}
