import SwiftUI

struct LowAnalyticalConfidenceScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Low analytical confidence")
                        .font(.title3.bold())
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    tipRow(icon: "rotate.3d", text: "Try a different watch position — some positions are easier to read than others.")
                    tipRow(icon: "iphone.gen3", text: "Press the phone firmly against the caseback for solid acoustic contact.")
                    tipRow(icon: "ear", text: "Move to a quieter room — background noise can mask quieter ticks.")
                    tipRow(icon: "wrench.and.screwdriver", text: "If this happens in every position, your watch may be running on insufficient amplitude — consider service.")
                    Spacer(minLength: 0)
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
