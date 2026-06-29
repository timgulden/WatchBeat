import SwiftUI

/// The single combined "listen + measure" screen.
///
/// Replaces the previous two-screen flow (Monitoring + Recording). When
/// the user taps Listen on the Idle screen, audio capture + the picker
/// analysis loop both start immediately and the user sees this one
/// screen until either:
///   - Auto-stop fires (a 15-s rolling window passed the quality gates)
///     and a result is computed; or
///   - The 60-s budget runs out and the failure routing ladder fires; or
///   - The user taps Cancel.
///
/// Upper square: EKG-style band-energy trace at top, standard-rate bars
/// below, current best-band frequency label under the bars. Lower square:
/// short instructional tips. Bottom row: Cancel only — no Measure
/// button.
struct RecordingScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        SquareScreenLayout(rotation: coordinator.latchedUIRotation, bigOnTop: true) {
            SimpleTipsBlock(title: "Analyzing…", tips: [
                ("hand.raised", "Hold steady."),
                ("ear", "Stay quiet."),
                ("clock", "Usually finishes in 15 seconds."),
                ("hourglass", "Up to 60 seconds with a weak signal."),
            ])
        } bigSquare: {
            ListenPanel(data: coordinator.spectrogramData)
        } controls: {
            VStack(spacing: 10) {
                BottomRow(cancelAction: { coordinator.cancelMeasurement() })
            }
        }
    }
}

/// Composite of the trace + bars + band-Hz label, fills the upper
/// (big) square of the Listen screen.
struct ListenPanel: View {
    @ObservedObject var data: SpectrogramData

    var body: some View {
        VStack(spacing: 6) {
            // Trace and bars share the upper-square space roughly equally.
            BandTraceView(data: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            BeatRateBarsView(data: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(bandLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 14)
        }
        .padding(8)
    }

    private var bandLabel: String {
        String(format: "Listening at %.1f kHz", data.bestBandHz / 1000.0)
    }
}
