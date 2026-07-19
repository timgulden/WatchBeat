import SwiftUI

/// First screen of the Position Study flow: shows the grip diagram
/// (caseback against the phone's bottom edge, crown left) and explains
/// what's about to happen. Motion + mic stay off until Begin.
struct StudyIntroScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        SquareScreenLayout(bigOnTop: true, controlsHeight: 130) {
            VStack(alignment: .leading, spacing: 14) {
                tipRow(icon: "1.circle", text: "Hold the watch caseback against the phone's bottom edge, crown pointing left.")
                tipRow(icon: "2.circle", text: "Move the phone into each of 5 positions — the app tells you which and starts by itself.")
                tipRow(icon: "3.circle", text: "Hold steady while each reading runs (15–60 seconds).")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        } bigSquare: {
            VStack(spacing: 8) {
                Image("WatchPositioningDiagram")
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Diagram: watch caseback pressed against the phone's bottom edge, crown pointing left")
                Text("Keep this grip for the whole study")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        } controls: {
            VStack(spacing: 10) {
                ActionButton(title: "Begin Study") {
                    coordinator.beginStudyPositions()
                }
                BottomRow(cancelAction: { coordinator.cancelStudy() }) {
                    EmptyView()
                }
            }
        }
    }
}
