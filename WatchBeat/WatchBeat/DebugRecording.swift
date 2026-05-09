import Foundation
import WatchBeatCore

/// Manages the lifecycle of a single transient debug recording —
/// the WAV that backs the "Send Debug" feature on result/failure screens.
///
/// Lifecycle:
///   - `save(buffer:result:context:)` writes a WAV + JSON sidecar to the
///     OS temporary directory. Single fixed filename means a new save
///     overwrites any prior file.
///   - `currentRecordingURL` returns the WAV URL if a recording exists,
///     nil otherwise. The Send Debug UI uses this to decide whether the
///     button is enabled and to attach to the share sheet.
///   - `discard()` deletes both the WAV and JSON sidecar. Called by the
///     coordinator when the user moves away from the result/failure
///     screen (Try Again, Measure Again, Listen) — i.e., the recording
///     belongs to the screen that's currently showing, and is gone the
///     moment that screen is dismissed.
///   - `cleanupStaleOnLaunch()` is called once at app start to remove
///     any leftover recording from a previous session that crashed or
///     was force-quit before normal cleanup ran.
///
/// Privacy: the temporary directory is sandboxed to this app, not visible
/// in the iOS Files app, and iOS itself purges it periodically. The
/// recording is held only while the user is actively viewing a result
/// or failure screen; persistence beyond that lives only at the user's
/// explicit choice (Send Debug → share sheet → user picks an app and
/// sends from there).
final class DebugRecording {
    /// Diagnostic context attached as a JSON sidecar. Lets the developer
    /// correlate the audio with what the app actually computed without
    /// asking the user to describe everything.
    struct Context: Codable {
        let appVersion: String
        let buildNumber: String
        let deviceModel: String
        let iOSVersion: String
        let measuredRateBPH: Int
        let rateErrorSecondsPerDay: Double
        let beatErrorMilliseconds: Double?
        let amplitudeDegrees: Double?
        let liftAngleDegrees: Double
        let qualityScore: Double
        let confirmedFraction: Double
        let isLowConfidence: Bool
        let outcome: String   // "result" / "weakSignal" / "lowAnalyticalConfidence" / "rateConfusion" / "needsService"
        let timestamp: String // ISO-8601
    }

    private let wavURL: URL
    private let jsonURL: URL
    private(set) var currentContext: Context?

    init() {
        let dir = FileManager.default.temporaryDirectory
        self.wavURL = dir.appendingPathComponent("watchbeat_debug_recording.wav")
        self.jsonURL = dir.appendingPathComponent("watchbeat_debug_recording.json")
    }

    var currentRecordingURL: URL? {
        FileManager.default.fileExists(atPath: wavURL.path) ? wavURL : nil
    }

    /// Save (or overwrite) the current recording. Both WAV and JSON
    /// sidecar are written; either's absence on later read indicates a
    /// failed save.
    func save(buffer: WatchBeatCore.AudioBuffer, context: Context) {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: jsonURL)

        // Float32 PCM WAV (matches the buffer's native format and avoids
        // a quantization step that would discolor diagnostic audio).
        let samples = buffer.samples
        let sampleRate = UInt32(buffer.sampleRate)
        let numSamples = UInt32(samples.count)
        let dataSize = numSamples * 4
        let fileSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(3).littleEndian) { Data($0) })  // 3 = IEEE float
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // mono
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: (sampleRate * 4).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(4).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(32).littleEndian) { Data($0) })
        data.append(contentsOf: "data".utf8)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try? data.write(to: wavURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let json = try? encoder.encode(context) {
            try? json.write(to: jsonURL)
        }
        currentContext = context
    }

    func discard() {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: jsonURL)
        currentContext = nil
    }

    /// Called once at app start. Removes any recording left over from a
    /// previous session (app crashed before cleanup, force-quit while a
    /// result was visible, etc.).
    func cleanupStaleOnLaunch() {
        discard()
    }

    /// URLs to attach to the share sheet — WAV + JSON sidecar. Returns
    /// empty if there's no current recording (caller should check and
    /// disable the Send button instead).
    var attachmentURLs: [URL] {
        guard FileManager.default.fileExists(atPath: wavURL.path) else { return [] }
        var urls = [wavURL]
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            urls.append(jsonURL)
        }
        return urls
    }
}
