import SwiftUI

/// First screen of the Position Study flow: shows the grip diagram
/// (caseback against the phone's bottom edge, crown left) and explains
/// what's about to happen. Motion + mic stay off until Begin.
///
/// Deliberately not SquareScreenLayout: this screen never rotates, and
/// the square slots force the tips into a narrow column that clips on
/// smaller phones. Layout metrics (title, controls height/padding)
/// mirror SquareScreenLayout so the Begin button lands in the same
/// position as Idle's Listen button.
struct StudyIntroScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            VStack(spacing: 8) {
                Image("WatchPositioningDiagram")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 400)
                    .accessibilityLabel("Diagram: watch caseback pressed against the phone's bottom edge, crown pointing left")
                Text("Keep this grip for the whole study")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 14) {
                tipRow(icon: "1.circle", text: "Hold the watch caseback against the phone's bottom edge, crown pointing left.")
                tipRow(icon: "2.circle", text: "Move the phone into each of 5 positions — the app tells you which and starts by itself.")
                tipRow(icon: "3.circle", text: "Hold steady while each reading runs (15–60 seconds).")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                ActionButton(title: "Begin Study") {
                    coordinator.beginStudyPositions()
                }
                BottomRow(cancelAction: { coordinator.cancelStudy() }) {
                    EmptyView()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(height: 130)
        }
    }
}
