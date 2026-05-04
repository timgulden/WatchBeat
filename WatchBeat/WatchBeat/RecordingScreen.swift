import SwiftUI

struct RecordingScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = elapsedTime()
            let current = coordinator.currentQuality
            let best = coordinator.bestQualitySoFar

            SquareScreenLayout(rotation: coordinator.latchedUIRotation) {
                WatchLogo(showHand: true,
                          angle: recordingWheelAngle(elapsed: elapsed),
                          showDialBackdrop: true)
            } bigSquare: {
                VStack(spacing: 8) {
                    ListeningCaption(phaseTitle: phaseTitle(elapsed: elapsed),
                                     subtitle: phaseSubtitle(elapsed: elapsed),
                                     position: coordinator.currentPosition)
                    FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                        .frame(maxHeight: .infinity)
                }
                .padding(12)
            } controls: {
                VStack(spacing: 10) {
                    VStack(spacing: 4) {
                        // Current quality — small
                        HStack(spacing: 4) {
                            Text("Current:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(current)%")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(MeasurementConstants.qualityColor(current))
                        }
                        // Progress bar — tracks best
                        ProgressView(value: min(Double(best), 80), total: 80)
                            .progressViewStyle(.linear)
                            .tint(MeasurementConstants.qualityColor(best))
                        // Best quality — prominent
                        HStack(spacing: 4) {
                            Text("Best:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(best)%")
                                .font(.title2.bold().monospacedDigit())
                                .foregroundStyle(MeasurementConstants.qualityColor(best))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Measurement quality")
                    .accessibilityValue("Current \(current) percent, best \(best) percent")
                    BottomRow(cancelAction: { coordinator.cancelMeasurement() })
                }
            }
        }
    }

    private func elapsedTime() -> Double {
        guard let start = coordinator.recordingStartTime else { return 0 }
        return min((ContinuousClock.now - start).asSeconds, coordinator.maxRecordingTime)
    }

    /// Wheel starts at 12:00 (angle 0) and sweeps 360° clockwise back to
    /// 12:00 over `maxRecordingTime`, at 6°/sec.
    private func recordingWheelAngle(elapsed: Double) -> Double {
        let progress = min(elapsed / coordinator.maxRecordingTime, 1.0)
        return progress * 360
    }

    /// Phase title (line 2) tracks the wheel's wedge boundaries:
    /// - 0–15 s post-Measure: "Measuring..." (wedge 0°–90°)
    /// - 15–20 s:              "Analyzing..." (wedge 90°–120°)
    /// - 20+ s:                "Refining..."  (wedge 120°–360°)
    private func phaseTitle(elapsed: Double) -> String {
        let measuringEnd = MeasurementConstants.analysisWindow         // 15 s
        let analyzingEnd = measuringEnd + 5.0                          // +5 s slice
        if elapsed < measuringEnd { return "Measuring..." }
        if elapsed < analyzingEnd { return "Analyzing..." }
        return "Refining..."
    }

    /// Descriptive subtitle (line 3) — mirrors phase but in plain language
    /// for the user.
    private func phaseSubtitle(elapsed: Double) -> String {
        let measuringEnd = MeasurementConstants.analysisWindow
        let analyzingEnd = measuringEnd + 5.0
        if elapsed < measuringEnd { return "Collecting data." }
        if elapsed < analyzingEnd { return "Processing data." }
        return "Searching for stronger signal."
    }
}
