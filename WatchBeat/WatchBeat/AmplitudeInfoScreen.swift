import SwiftUI

/// Informational screen presented when the user taps the "i" button next
/// to the Amplitude display on the result screen. Visually mirrors the
/// failure screens (icon at top, tip rows, dismiss button at bottom)
/// but uses an info icon instead of a warning. Presented as a sheet, so
/// iOS's native swipe-down also dismisses it.
struct AmplitudeInfoScreen: View {
    @Environment(\.dismiss) private var dismiss

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
                    Text("About Amplitude")
                        .font(.title3.bold())
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    tipRow(icon: "arrow.left.and.right.circle",
                           text: "Amplitude is the angular swing of the balance wheel. Higher generally means better health: more energy, better timekeeping.")
                    tipRow(icon: "iphone.gen3",
                           text: "Position matters. Dial-up and dial-down are typically highest. Pendant positions (crown up/down, 6 up, 12 up) run 30°-60° lower due to extra pivot friction.")
                    tipRow(icon: "wrench.and.screwdriver",
                           text: "Power reserve and service state matter. Amplitude drops 30°-50° from full wind to 24 hours later, and a watch needing service runs 30°-80° lower than freshly serviced.")
                    tipRow(icon: "chart.bar.doc.horizontal",
                           text: "Typical healthy ranges (full wind, dial up): modern Swiss automatic 280°-310°, modern Japanese 250°-290°, vintage Swiss lever 260°-290°, vintage pin-lever 200°-260°. Below ~200° suggests service is due.")
                    tipRow(icon: "exclamationmark.triangle",
                           text: "Amplitude readings depend on the lift angle being correct. If your reading seems off, check the lift angle for your specific caliber.")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Spacer()

            ActionButton(title: "Dismiss") {
                dismiss()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }
}
