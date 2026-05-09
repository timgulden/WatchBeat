import SwiftUI
import UIKit

/// Modal presented when the user taps "Send Debug" on a result or
/// failure screen. Discloses what's being shared, asks for the watch
/// name and any notes, and presents the iOS share sheet so the user
/// can send via Mail / Messages / AirDrop / etc.
///
/// Privacy framing: the disclosure copy explicitly states that the
/// recording captures audio from the room during the measurement
/// period (15 s recording window, up to 60 s total session). Apple's
/// review process scrutinizes anything that transmits audio off-device;
/// this sheet's role is to make consent unambiguous.
struct DebugReportSheet: View {
    let debugRecording: DebugRecording
    @Environment(\.dismiss) private var dismiss
    @State private var watchName: String = ""
    @State private var notes: String = ""
    @State private var presentingShareSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("WatchBeat")
                    .font(.largeTitle.bold())
                    .padding(.top, 12)

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("Send Debug Recording")
                            .font(.title3.bold())
                    }
                    .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sends the audio recording from this measurement to the developer to help diagnose problems with your watch's reading.")
                            .font(.subheadline)

                        Text("The recording captures whatever sounds were in the room during the measurement (up to 60 seconds), not just the watch.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Watch")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("e.g., Rolex Submariner 1680", text: $watchName)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notes (optional)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("What's puzzling about this reading?", text: $notes, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(3...6)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.secondary)
                    Button("Send") {
                        presentingShareSheet = true
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .buttonStyle(.borderedProminent)
                    .disabled(debugRecording.currentRecordingURL == nil)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .sheet(isPresented: $presentingShareSheet, onDismiss: { dismiss() }) {
                ShareSheet(activityItems: shareItems)
            }
        }
    }

    /// Items handed to UIActivityViewController. The body string carries
    /// the user-typed context plus a compact diagnostic dump; the WAV
    /// (and JSON sidecar) are file attachments.
    private var shareItems: [Any] {
        var items: [Any] = []

        var bodyLines: [String] = []
        if !watchName.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.append("Watch: \(watchName)")
        }
        if !notes.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.append("Notes: \(notes)")
        }
        if let ctx = debugRecording.currentContext {
            bodyLines.append("")
            bodyLines.append("--- App diagnostics ---")
            bodyLines.append("Outcome: \(ctx.outcome)")
            bodyLines.append("Rate: \(ctx.measuredRateBPH) bph, \(String(format: "%+.1f", ctx.rateErrorSecondsPerDay)) s/day")
            if let be = ctx.beatErrorMilliseconds {
                bodyLines.append("Beat error: \(String(format: "%.2f", be)) ms")
            }
            if let amp = ctx.amplitudeDegrees {
                bodyLines.append("Amplitude: \(Int(amp))°")
            }
            bodyLines.append("Lift angle: \(Int(ctx.liftAngleDegrees))°")
            bodyLines.append("Quality: \(Int(ctx.qualityScore * 100))% / Confirmed: \(Int(ctx.confirmedFraction * 100))% / LowConf: \(ctx.isLowConfidence)")
            bodyLines.append("App: \(ctx.appVersion) (\(ctx.buildNumber)) on \(ctx.deviceModel) iOS \(ctx.iOSVersion)")
            bodyLines.append("Recorded: \(ctx.timestamp)")
        }
        items.append(bodyLines.joined(separator: "\n"))
        items.append(contentsOf: debugRecording.attachmentURLs)
        return items
    }
}

/// UIActivityViewController bridge.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
