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
    /// (and JSON sidecar) are file attachments — copied to uniquely-
    /// named temp files at share time so the receiver sees something
    /// like `Timex1_2026-05-09_14-32-15.wav` instead of the generic
    /// fixed on-disk filename.
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
        items.append(contentsOf: namedAttachmentURLs())
        return items
    }

    /// Bundle the WAV and JSON sidecar into a single .zip archive named
    /// `WatchName_YYYY-MM-DD_HH-MM-SS.zip`, then return its URL as the
    /// share-sheet attachment. The single-archive approach is important
    /// because iMessage transcodes any standalone audio attachment to
    /// .m4a in transit (unavoidable, controlled by iOS). A zip avoids
    /// that — bytes pass through unchanged. AirDrop and Mail also
    /// preserve the WAV's bytes inside the zip.
    ///
    /// The zip is generated via NSFileCoordinator's .forUploading
    /// reading option, the same iOS-native packaging used when AirDrop
    /// shares a folder. No third-party dependencies.
    ///
    /// On-disk single-file invariant (used for cleanup) is preserved —
    /// the zip and its source directory are temp files that iOS will
    /// purge.
    private func namedAttachmentURLs() -> [URL] {
        let originals = debugRecording.attachmentURLs
        guard !originals.isEmpty else { return [] }

        let base = filenameBase()
        let tmp = FileManager.default.temporaryDirectory

        // Build a directory holding the renamed source files. Using a
        // directory (not a single file) is what triggers NSFileCoordinator
        // to produce a .zip — coordinating a single file would return
        // the file itself, not a zip.
        let stagingDir = tmp.appendingPathComponent("WatchBeatDebug_\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: stagingDir)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            // If we can't even create the staging dir, fall back to
            // the originals (filename will be the on-disk fixed name,
            // and Messages will transcode the WAV — but the share
            // still works).
            return originals
        }
        for url in originals {
            let ext = url.pathExtension
            let dest = stagingDir.appendingPathComponent("\(base).\(ext)")
            try? FileManager.default.copyItem(at: url, to: dest)
        }

        // Coordinate a read with .forUploading — iOS produces a .zip of
        // the directory at a temp URL. We then copy that to a named
        // location so the share sheet shows the meaningful filename.
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var producedZipURL: URL?
        coordinator.coordinate(readingItemAt: stagingDir,
                               options: [.forUploading],
                               error: &coordError) { providedURL in
            // providedURL is a temp .zip iOS will clean up after this
            // block returns. Copy it to a stable name in tmp/.
            let dest = tmp.appendingPathComponent("\(base).zip")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: providedURL, to: dest)
                producedZipURL = dest
            } catch {
                producedZipURL = nil
            }
        }
        try? FileManager.default.removeItem(at: stagingDir)

        if let zipURL = producedZipURL {
            return [zipURL]
        } else {
            // Zip creation failed (rare) — fall back to attaching the
            // raw files. Messages may transcode the WAV but the share
            // still happens.
            return originals
        }
    }

    /// Sanitized "WatchName_YYYY-MM-DD_HH-MM-SS" from the user-typed
    /// watch name and the recording's timestamp.
    private func filenameBase() -> String {
        let trimmedName = watchName.trimmingCharacters(in: .whitespaces)
        let safeName: String
        if trimmedName.isEmpty {
            safeName = "WatchBeat"
        } else {
            // Replace whitespace with underscores; strip everything that
            // isn't alphanumeric, underscore, or hyphen. Keeps filenames
            // safe across iOS / macOS / iCloud / shared storage.
            let collapsed = trimmedName.replacingOccurrences(of: " ", with: "_")
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
            let cleaned = String(collapsed.filter { allowed.contains($0) })
            safeName = cleaned.isEmpty ? "WatchBeat" : cleaned
        }

        // Convert ISO-8601 timestamp (e.g. "2026-05-09T14:32:15Z") to a
        // filename-safe variant ("2026-05-09_14-32-15"). Falls back to
        // "now" if context is missing.
        let raw = debugRecording.currentContext?.timestamp ?? ISO8601DateFormatter().string(from: Date())
        let timeStamp = raw
            .replacingOccurrences(of: "T", with: "_")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "Z", with: "")
        return "\(safeName)_\(timeStamp)"
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
