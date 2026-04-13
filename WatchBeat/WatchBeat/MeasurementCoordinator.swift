import SwiftUI
import Combine
import WatchBeatCore

/// Orchestrates the capture-then-analyze workflow and publishes state for the UI.
@MainActor
final class MeasurementCoordinator: ObservableObject {

    enum State: Equatable {
        case idle
        case monitoring  // live level meter before recording
        case requestingPermission
        case recording(elapsed: Double, total: Double)
        case analyzing
        case result(MeasurementDisplayData)
        case error(String)
    }

    /// Formatted measurement data for display.
    struct MeasurementDisplayData: Equatable {
        let rateBPH: Int
        let rateErrorSecondsPerDay: String
        let beatErrorMilliseconds: String?
        let qualityPercent: Int
        let tickCount: Int
        let diagnosticText: String
    }

    @Published var state: State = .idle
    @Published var audioLevel: Float = 0

    /// User-selected beat rate, or nil for auto-detect.
    @Published var selectedRate: StandardBeatRate? = nil

    /// Capture duration in seconds.
    var captureDuration: Double = 30.0

    private let captureService = AudioCaptureService()
    private let levelMonitor = AudioLevelMonitor()
    private let pipeline = MeasurementPipeline()
    private var recordingTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    /// Start the live level monitor so the user can position the watch.
    func startMonitoring() {
        do {
            try levelMonitor.start()
            state = .monitoring
            // Poll the level monitor and publish updates
            levelTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    self.audioLevel = self.levelMonitor.level
                }
            }
        } catch {
            state = .error("Could not start audio monitor: \(error.localizedDescription)")
        }
    }

    /// Stop monitoring and go back to idle.
    func stopMonitoring() {
        levelTask?.cancel()
        levelTask = nil
        levelMonitor.stop()
        state = .idle
        audioLevel = 0
    }

    /// Start a measurement: stop monitor, record, analyze, display result.
    func startMeasurement() {
        // Stop the level monitor — capture will start its own engine
        levelTask?.cancel()
        levelTask = nil
        levelMonitor.stop()

        recordingTask?.cancel()
        recordingTask = Task {
            await performMeasurement()
        }
    }

    /// Cancel an in-progress measurement.
    func cancelMeasurement() {
        recordingTask?.cancel()
        recordingTask = nil
        levelTask?.cancel()
        levelTask = nil
        levelMonitor.stop()
        state = .idle
        audioLevel = 0
    }

    private func performMeasurement() async {
        // Request microphone permission
        state = .requestingPermission
        let granted = await captureService.requestPermission()
        guard granted else {
            state = .error("Microphone access denied. Please enable it in Settings.")
            return
        }

        // Start recording with progress updates
        state = .recording(elapsed: 0, total: captureDuration)

        let progressTask = Task {
            let start = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let elapsed = (ContinuousClock.now - start).asSeconds
                await MainActor.run {
                    if case .recording = self.state {
                        self.state = .recording(elapsed: min(elapsed, self.captureDuration), total: self.captureDuration)
                    }
                }
            }
        }

        do {
            let buffer = try await captureService.capture(duration: captureDuration)
            progressTask.cancel()

            guard !Task.isCancelled else {
                state = .idle
                return
            }

            // Save raw audio for debugging
            saveRawAudio(buffer)

            // Analyze
            state = .analyzing

            let rateOverride = self.selectedRate
            let (result, diagnostics) = await Task.detached { [pipeline] in
                pipeline.measureWithDiagnostics(buffer, knownRate: rateOverride)
            }.value

            guard !Task.isCancelled else {
                state = .idle
                return
            }

            // Build diagnostic text
            let scoresText = diagnostics.rateScores
                .sorted { $0.magnitude > $1.magnitude }
                .prefix(3)
                .map { "\($0.rate.rawValue)bph: \(String(format: "%.1f", $0.magnitude))" }
                .joined(separator: ", ")

            let rateMode = rateOverride != nil ? "Manual: \(rateOverride!.rawValue) bph" : "Auto-detect"

            let diagText = """
            Rate mode: \(rateMode)
            Audio: \(captureService.lastConfigInfo)
            Raw peak: \(String(format: "%.4f", diagnostics.rawPeakAmplitude))
            Period: \(String(format: "%.4f", diagnostics.periodEstimate.measuredHz)) Hz
            Confidence: \(String(format: "%.1f%%", diagnostics.periodEstimate.confidence * 100))
            Ticks: \(diagnostics.tickCount)
            Top rates: \(scoresText)
            Sample rate: \(Int(diagnostics.sampleRate)) Hz
            Samples: \(diagnostics.sampleCount)
            """

            let displayData = MeasurementDisplayData(
                rateBPH: result.snappedRate.rawValue,
                rateErrorSecondsPerDay: formatRateError(result.rateErrorSecondsPerDay),
                beatErrorMilliseconds: result.beatErrorMilliseconds.map { formatBeatError($0) },
                qualityPercent: Int(result.qualityScore * 100),
                tickCount: result.tickCount,
                diagnosticText: diagText
            )
            state = .result(displayData)

        } catch {
            progressTask.cancel()
            if !Task.isCancelled {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Save raw audio as a 32-bit float WAV for offline analysis.
    private func saveRawAudio(_ buffer: WatchBeatCore.AudioBuffer) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "watchbeat_\(formatter.string(from: Date())).wav"
        let url = docs.appendingPathComponent(filename)

        // Write a minimal WAV file (32-bit float, mono)
        let samples = buffer.samples
        let sampleRate = UInt32(buffer.sampleRate)
        let numSamples = UInt32(samples.count)
        let dataSize = numSamples * 4 // 4 bytes per float
        let fileSize = 36 + dataSize

        var data = Data()
        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        data.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // chunk size
        data.append(withUnsafeBytes(of: UInt16(3).littleEndian) { Data($0) })  // IEEE float
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // mono
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) }) // sample rate
        data.append(withUnsafeBytes(of: (sampleRate * 4).littleEndian) { Data($0) }) // byte rate
        data.append(withUnsafeBytes(of: UInt16(4).littleEndian) { Data($0) })  // block align
        data.append(withUnsafeBytes(of: UInt16(32).littleEndian) { Data($0) }) // bits per sample
        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        try? data.write(to: url)
        print("Saved raw audio to: \(url.path)")
    }

    private func formatRateError(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", value)) s/day"
    }

    private func formatBeatError(_ value: Double) -> String {
        return "\(String(format: "%.1f", value)) ms"
    }
}

// MARK: - Duration helper

private extension Duration {
    var asSeconds: Double {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
