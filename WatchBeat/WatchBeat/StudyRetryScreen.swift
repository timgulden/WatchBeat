import SwiftUI

/// In-study failure screen. A reading that would normally route to Weak
/// Signal / Low Confidence / etc. lands here instead, so the positions
/// already measured are never lost. Retry re-enters positioning for the
/// same position; Skip records it as skipped and moves on.
struct StudyRetryScreen: View {
    let reason: String
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        SquareScreenLayout(controlsHeight: 130) {
            WatchLogo()
        } bigSquare: {
            VStack(alignment: .leading, spacing: 14) {
                Text("No reading in \(coordinator.study?.target?.displayName ?? "this position")")
                    .font(.title3.bold())
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                tipRow(icon: "hand.raised", text: "Press the watch firmly against the phone and hold steady.")
                tipRow(icon: "ear", text: "A quieter environment helps.")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        } controls: {
            VStack(spacing: 10) {
                ActionButton(title: "Retry Position") {
                    coordinator.retryStudyPosition()
                }
                BottomRow(cancelAction: { coordinator.cancelStudy() }) {
                    Button("Skip Position") {
                        coordinator.skipStudyPosition()
                    }
                    .font(.footnote.weight(.bold))
                }
            }
        }
    }
}
