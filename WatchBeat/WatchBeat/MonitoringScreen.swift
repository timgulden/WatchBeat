import SwiftUI

struct MonitoringScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = sweepElapsed()
            let ready = elapsed >= MeasurementConstants.listenSweepDuration
            SquareScreenLayout(rotation: coordinator.latchedUIRotation) {
                WatchLogo(showHand: true,
                          angle: 0,
                          showDialBackdrop: true)
            } bigSquare: {
                VStack(spacing: 8) {
                    ListeningCaption(subtitle: "Look for the peak at your watch's beat rate",
                                     position: coordinator.currentPosition)
                    FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                        .frame(maxHeight: .infinity)
                }
                .padding(12)
            } controls: {
                VStack(spacing: 10) {
                    ActionButton(title: "Measure") {
                        coordinator.startMeasurement()
                    }
                    .disabled(!ready)
                    BottomRow(cancelAction: { coordinator.stopMonitoring() })
                }
            }
        }
    }

    /// Seconds since monitoring began (for the Measure-button gate).
    private func sweepElapsed() -> Double {
        guard let start = coordinator.monitoringStartTime else { return 0 }
        return (ContinuousClock.now - start).asSeconds
    }
}
