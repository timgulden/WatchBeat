import SwiftUI

struct WeakSignalScreen: View {
    /// Diagnostic info string (q=…, confirmed=…, etc.) — captured for
    /// support but not currently displayed to the user.
    let diagnostic: String
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.slash")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Couldn't find a clear signal")
                        .font(.title3.bold())
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    Text("The watch was likely too faint over the background noise. A few things often help:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    tipRow(icon: "ear", text: "Move to a quieter room.")
                    tipRow(icon: "hand.tap", text: "Hold the phone firmly against the watch.")
                    tipRow(icon: "iphone.slash", text: "Remove a thick phone case if you have one.")
                    Spacer().frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

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
    }
}
