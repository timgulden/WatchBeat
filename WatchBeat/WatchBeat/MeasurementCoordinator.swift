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

    /// Current live quality percentage during recording.
    private var liveQuality: Int = 0
    /// Best quality seen so far during this recording session.
    private(set) var bestQualitySoFar: Int = 0
    /// Set by the deadline task when maxRecordingTime is reached.
    private var timedOut: Bool = false

    /// Analysis window duration in seconds.
    let analysisWindow: Double = 15.0
    /// Minimum quality to auto-accept a result (great).
    let qualityThreshold: Double = 0.80
    /// Minimum quality to show results (below this = try again).
    let minimumDisplayQuality: Double = 0.30
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

        state = .recording(elapsed: 0, liveQuality: 0)
        liveQuality = 0
        bestQualitySoFar = 0
        timedOut = false

        let startTime = ContinuousClock.now
        var bestResult: (MeasurementResult, PipelineDiagnostics)?
        var bestQuality: Double = 0

        // Timer task: updates UI every 200ms
        monitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let elapsed = (ContinuousClock.now - startTime).asSeconds
                self.ratePowers = self.frequencyMonitor.ratePowers
                self.state = .recording(elapsed: elapsed, liveQuality: self.liveQuality)
            }
        }

        // Deadline task: sets timedOut flag after exactly maxRecordingTime
        let deadlineTask = Task {
            try? await Task.sleep(for: .seconds(self.maxRecordingTime))
            await MainActor.run { self.timedOut = true }
        }

        // Wait for enough audio
        while !Task.isCancelled && !timedOut {
            let elapsed = (ContinuousClock.now - startTime).asSeconds
            if elapsed >= analysisWindow { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        // Analysis loop — exits when quality met OR timedOut
        while !Task.isCancelled && !timedOut {
            if let buffer = await captureService.getRecentAudio(duration: analysisWindow) {
                let (result, diagnostics) = await Task.detached { [pipeline] in
                    pipeline.measureWithDiagnostics(buffer)
                }.value

                let quality = result.qualityScore
                liveQuality = Int(quality * 100)
                bestQualitySoFar = max(bestQualitySoFar, liveQuality)

                if quality > bestQuality {
                    bestQuality = quality
                    bestResult = (result, diagnostics)
                }

                if quality >= qualityThreshold {
                    break
                }
            }

            // Sleep in short intervals so we notice timedOut quickly
            for _ in 0..<6 {
                if timedOut || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        deadlineTask.cancel()

        // Save audio BEFORE stopping the engine
        var savedBuffer: WatchBeatCore.AudioBuffer?
        if let best = bestResult {
            savedBuffer = await captureService.getRecentAudio(duration: analysisWindow)
            if let buf = savedBuffer { saveRawAudio(buf, result: best.0) }
        }

        // Stop timer and recording
        monitorTask?.cancel()
        monitorTask = nil
        captureService.stopRecording()

        guard !Task.isCancelled else {
            state = .idle
            return
        }

        // Show result if quality meets minimum threshold, otherwise show error
        if let (result, diagnostics) = bestResult, result.qualityScore >= minimumDisplayQuality {

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
            state = .error("Could not get a clear enough signal. Press the phone firmly against the caseback in a quiet room and watch for the frequency bars.")
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
