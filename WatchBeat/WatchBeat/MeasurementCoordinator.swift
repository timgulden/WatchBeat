import SwiftUI
import Combine
import WatchBeatCore

/// Orchestrates the capture-and-analyze workflow.
///
/// Flow: Listen (see frequency bars) → Measure (continuous recording with rolling
/// 15-second analysis every 3 seconds) → auto-stop when quality ≥ 50% → show result.
@MainActor
final class MeasurementCoordinator: ObservableObject {

    enum State: Equatable {
        case idle
        case monitoring        // frequency bars, positioning
        case recording(elapsed: Double, liveQuality: Int)  // recording + analyzing
        case analyzing         // final analysis
        case result(MeasurementDisplayData)
        case error(String)
    }

    struct MeasurementDisplayData: Equatable {
        let rateBPH: Int
        let rateError: Double           // raw value for dial
        let rateErrorFormatted: String
        let beatErrorMs: Double?        // raw value
        let beatErrorFormatted: String?
        let qualityPercent: Int
        let tickCount: Int
        let diagnosticText: String
        /// Tick residuals in milliseconds for the timegrapher plot.
        /// Each entry: (beatIndex, residualMs, isEvenBeat)
        let tickResiduals: [(index: Int, residualMs: Double, isEven: Bool)]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rateBPH == rhs.rateBPH && lhs.rateError == rhs.rateError &&
            lhs.qualityPercent == rhs.qualityPercent && lhs.tickCount == rhs.tickCount
        }
    }

    @Published var state: State = .idle
    @Published var ratePowers: [StandardBeatRate: Float] = [:]
    @Published var rawPeak: Float = 0

    /// Analysis window duration in seconds.
    let analysisWindow: Double = 15.0
    /// Minimum quality to auto-accept a result.
    let qualityThreshold: Double = 0.60
    /// How often to run analysis during recording (seconds).
    let analysisInterval: Double = 3.0
    /// Maximum recording time before giving up.
    let maxRecordingTime: Double = 60.0

    private let captureService = AudioCaptureService()
    private let frequencyMonitor = FrequencyMonitor()
    private let pipeline = MeasurementPipeline()
    private var recordingTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    // MARK: - Monitoring

    func startMonitoring() {
        do {
            try frequencyMonitor.start()
            state = .monitoring
            monitorTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    self.ratePowers = self.frequencyMonitor.ratePowers
                    self.rawPeak = self.frequencyMonitor.rawPeak
                }
            }
        } catch {
            state = .error("Could not start audio: \(error.localizedDescription)")
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        frequencyMonitor.stop()
        state = .idle
        ratePowers = [:]
    }

    // MARK: - Recording + rolling analysis

    func startMeasurement() {
        // Stop the frequency monitor's audio engine
        frequencyMonitor.stop()

        recordingTask?.cancel()
        recordingTask = Task { await performContinuousMeasurement() }
    }

    func cancelMeasurement() {
        recordingTask?.cancel()
        recordingTask = nil
        captureService.stopRecording()
        monitorTask?.cancel()
        monitorTask = nil
        frequencyMonitor.stop()
        state = .idle
        ratePowers = [:]
    }

    private func performContinuousMeasurement() async {
        // Request permission
        let granted = await captureService.requestPermission()
        guard granted else {
            state = .error("Microphone access denied.")
            return
        }

        // Set up frequency monitor to receive samples during recording
        frequencyMonitor.initializeForExternalFeed(sampleRate: 48000)
        captureService.onSamples = { [weak self] samples in
            self?.frequencyMonitor.feedSamples(samples)
        }

        // Start continuous recording
        do {
            await captureService.resetBuffer()
            try captureService.startRecording()
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        // Start frequency bar updates
        monitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self.ratePowers = self.frequencyMonitor.ratePowers
            }
        }

        state = .recording(elapsed: 0, liveQuality: 0)

        let startTime = ContinuousClock.now
        var bestResult: (MeasurementResult, PipelineDiagnostics)?
        var bestQuality: Double = 0

        // Rolling analysis loop
        while !Task.isCancelled {
            let elapsed = (ContinuousClock.now - startTime).asSeconds

            // Wait until we have enough audio for a window
            if elapsed < analysisWindow {
                state = .recording(elapsed: elapsed, liveQuality: 0)
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }

            // Check timeout
            if elapsed > maxRecordingTime {
                break
            }

            // Get most recent window and analyze
            if let buffer = await captureService.getRecentAudio(duration: analysisWindow) {
                let (result, diagnostics) = await Task.detached { [pipeline] in
                    pipeline.measureWithDiagnostics(buffer)
                }.value

                let quality = result.qualityScore
                state = .recording(elapsed: elapsed, liveQuality: Int(quality * 100))

                if quality > bestQuality {
                    bestQuality = quality
                    bestResult = (result, diagnostics)
                }

                // Auto-stop if quality threshold met
                if quality >= qualityThreshold {
                    break
                }
            }

            // Wait before next analysis
            try? await Task.sleep(for: .seconds(analysisInterval))
        }

        // Stop recording
        captureService.stopRecording()
        monitorTask?.cancel()

        guard !Task.isCancelled else {
            state = .idle
            return
        }

        // Save the best audio and show result
        if let (result, diagnostics) = bestResult {
            // Save the most recent audio
            if let buffer = await captureService.getRecentAudio(duration: analysisWindow) {
                saveRawAudio(buffer, result: result)
            }

            let scoresText = diagnostics.rateScores
                .sorted { $0.magnitude > $1.magnitude }
                .prefix(3)
                .map { "\($0.rate.rawValue)bph: \(String(format: "%.1f", $0.magnitude))" }
                .joined(separator: ", ")

            let diagText = """
            Audio: \(captureService.lastConfigInfo)
            Raw peak: \(String(format: "%.4f", diagnostics.rawPeakAmplitude))
            Period: \(String(format: "%.4f", diagnostics.periodEstimate.measuredHz)) Hz
            Confidence: \(String(format: "%.1f%%", diagnostics.periodEstimate.confidence * 100))
            Ticks: \(diagnostics.tickCount)
            Top rates: \(scoresText)
            """

            let tickResiduals = result.tickTimings.map {
                (index: $0.beatIndex, residualMs: $0.residualMs, isEven: $0.isEvenBeat)
            }

            let displayData = MeasurementDisplayData(
                rateBPH: result.snappedRate.rawValue,
                rateError: result.rateErrorSecondsPerDay,
                rateErrorFormatted: formatRateError(result.rateErrorSecondsPerDay),
                beatErrorMs: result.beatErrorMilliseconds,
                beatErrorFormatted: result.beatErrorMilliseconds.map { formatBeatError($0) },
                qualityPercent: Int(result.qualityScore * 100),
                tickCount: result.tickCount,
                diagnosticText: diagText,
                tickResiduals: tickResiduals
            )
            state = .result(displayData)
        } else {
            state = .error("Could not get a usable measurement. Try in a quieter environment with firmer contact.")
        }
    }

    // MARK: - File saving

    private func saveRawAudio(_ buffer: WatchBeatCore.AudioBuffer, result: MeasurementResult) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let q = Int(result.qualityScore * 100)
        let rate = result.snappedRate.rawValue
        let filename = "watchbeat_\(formatter.string(from: Date()))_\(rate)bph_q\(q).wav"
        let url = docs.appendingPathComponent(filename)

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
        data.append(withUnsafeBytes(of: UInt16(3).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: (sampleRate * 4).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(4).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(32).littleEndian) { Data($0) })
        data.append(contentsOf: "data".utf8)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try? data.write(to: url)
    }

    private func formatRateError(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", value)) s/day"
    }

    private func formatBeatError(_ value: Double) -> String {
        "\(String(format: "%.1f", value)) ms"
    }
}

private extension Duration {
    var asSeconds: Double {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
