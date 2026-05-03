import SwiftUI

struct MicUnavailableScreen: View {
    /// Optional underlying error string from AVAudioSession (when the engine
    /// failed to start). Captured for support but not currently displayed.
    let diagnostic: String?
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.slash")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Microphone unavailable")
                        .font(.title3.bold())
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    tipRow(icon: "phone.down", text: "End any active phone or video call.")
                    tipRow(icon: "waveform", text: "Quit any other recording app holding the microphone (Voice Memos, etc.).")
                    tipRow(icon: "lock.open", text: "Check microphone permission in Settings → Privacy & Security → Microphone.")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            ActionButton(title: "Try Again") {
                coordinator.startMonitoring()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }
}
