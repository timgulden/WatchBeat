import SwiftUI

/// Informational screen presented when the user taps the "i" button next
/// to the Lift Angle field on the result screen. Visually mirrors the
/// failure screens (icon at top, tip rows, dismiss button at bottom)
/// but uses an info icon instead of a warning. Presented as a sheet, so
/// iOS's native swipe-down also dismisses it.
struct LiftAngleInfoScreen: View {
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
                    Text("About Lift Angle")
                        .font(.title3.bold())
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    tipRow(icon: "gearshape.2",
                           text: "Lift angle is the angular range over which the escapement engages the balance wheel. It varies from watch to watch — typically 38° to 52°.")
                    tipRow(icon: "function",
                           text: "It is required for accurately calculating amplitude. Wrong lift angle gives a wrong amplitude reading, by a proportional amount.")
                    tipRow(icon: "clock.arrow.circlepath",
                           text: "Lift angle does NOT affect rate or beat error. Those readings are accurate regardless of what value is entered.")
                    tipRow(icon: "magnifyingglass",
                           text: "To find yours: search the web for your watch caliber and \"lift angle\". Common values: ETA 2824 = 50°, ETA 6497/6498 = 49°, Omega 8500 = 50°, Seagull ST3600 = 44°, vintage Swiss = 38°-44°, vintage pin-lever = 40°.")
                    tipRow(icon: "chart.bar",
                           text: "Healthy modern automatics typically show 270°-310° at full wind dial-up, dropping to 220°-250° in pendant positions. Vintage and pin-lever ranges vary widely.")
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
