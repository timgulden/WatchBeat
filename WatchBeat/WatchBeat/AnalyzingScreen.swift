import SwiftUI

/// Brief "Success" pause after a successful recording, before the
/// result page appears. The spectrogram from the recording session
/// stays visible (the SpectrogramMonitor has stopped feeding it so
/// the columns are frozen) with a green analysis-window tint so the
/// user has visual continuity between measurement and result.
struct AnalyzingScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        SquareScreenLayout(rotation: coordinator.latchedUIRotation, bigOnTop: true) {
            // Lower (small) square: success confirmation.
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Reading captured")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .aspectRatio(1, contentMode: .fit)
        } bigSquare: {
            SpectrogramSquare(
                data: coordinator.spectrogramData,
                status: "Success",
                tintColor: Color.green.opacity(0.25)
            )
        } controls: {
            VStack(spacing: 10) {
                BottomRow()
            }
        }
    }
}
