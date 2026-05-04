import SwiftUI

struct IdleScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator
    @State private var showCalibration = false

    var body: some View {
        SquareScreenLayout {
            WatchLogo()
                .onLongPressGesture(minimumDuration: 1.5) {
                    showCalibration = true
                }
        } bigSquare: {
            // Bullets at the top, diagram anchored to the bottom near the
            // Listen button. The square's size is fixed by SquareScreenLayout
            // so contents here never shift the wheel above.
            VStack(alignment: .leading, spacing: 10) {
                tipRow(icon: "waveform", text: "Place the iPhone mic close to your watch.")
                tipRow(icon: "arrow.right.to.line.compact", text: "Direct contact is not required but can help.")
                tipRow(icon: "applewatch", text: "On-wrist readings are fine for general use.")
                tipRow(icon: "arrow.down", text: "For automatic orientation detection, hold the watch against your iPhone as shown.")
                Image("WatchPositioningDiagram")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .accessibilityLabel("Diagram: watch caseback pressed against the bottom edge of an iPhone, crown pointing left.")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
        } controls: {
            VStack(spacing: 10) {
                ActionButton(title: "Listen") {
                    coordinator.startMonitoring()
                }
                BottomRow()
            }
        }
        .sheet(isPresented: $showCalibration) {
            CalibrationView()
        }
    }
}
