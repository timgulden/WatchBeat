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
                    Text("Reading wasn't conclusive")
                        .font(.title3.bold())
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    Text("The signal was clear in one direction but not the other. Often a second try is enough:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    tipRow(icon: "arrow.clockwise", text: "Try again — sometimes a fresh recording reads cleanly.")
                    tipRow(icon: "rotate.3d", text: "If it keeps happening, try a different watch position.")
                    tipRow(icon: "wrench.and.screwdriver", text: "Persistent in every position can indicate low amplitude or a worn movement.")
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
