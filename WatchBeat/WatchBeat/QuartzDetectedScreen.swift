import SwiftUI

/// Shown when the picker detects a strong 1 Hz peak with no comparable
/// mechanical-rate content — i.e., the user pointed the phone at a
/// quartz watch. Same visual style as the failure screens (warning at
/// top, tip rows, primary action button) but the framing is "this app
/// is for a different kind of watch" rather than "your recording was
/// bad."
struct QuartzDetectedScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text("Quartz Watch Detected")
                        .font(.title3.bold())
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    tipRow(icon: "battery.100",
                           text: "WatchBeat is designed for mechanical watches — hand-wound or automatic. Quartz watches use a battery and a tuning-fork crystal that ticks once per second, which doesn't fit the analysis model.")
                    tipRow(icon: "gearshape.2",
                           text: "Mechanical watches tick 5 to 10 times per second, producing a rich acoustic signature that WatchBeat is built to analyze.")
                    tipRow(icon: "magnifyingglass",
                           text: "If you're not sure: a watch with a smoothly sweeping second hand is mechanical; a watch whose second hand jumps once per second is quartz.")
                    tipRow(icon: "arrow.counterclockwise",
                           text: "If this is a mechanical watch and you got this message in error, try repositioning and measuring again — louder ambient noise at 1 Hz can occasionally be misread.")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Spacer()

            ActionButton(title: "Try Again") {
                coordinator.startMonitoring()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }
}
