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
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Signal too weak")
                        .font(.title3.bold())
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    tipRow(icon: "ear", text: "Move to a quieter room. Fans, HVAC, and conversation can mask the ticks.")
                    tipRow(icon: "iphone.slash", text: "Try removing a thick phone case for better acoustic contact.")
                    tipRow(icon: "arrow.down", text: "Press the watch firmly against your iPhone (see diagram).")
                    tipRow(icon: "arrow.left.and.right", text: "Slide the watch left or right to peak the bar for your watch's beat rate.")
                    tipRow(icon: "earpods", text: "For very quiet watches, try wired earbuds with mic — orientation detection won't work.")

                    Image("WatchPositioningDiagram")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .accessibilityLabel("Diagram: watch caseback pressed against the bottom edge of an iPhone, crown pointing left.")
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
