import SwiftUI
import Combine
import WatchBeatCore

/// Shared measurement and display constants.
enum MeasurementConstants {
    /// Auto-stop recording when quality reaches this threshold.
    static let autoStopQuality: Double = 0.80
    /// Minimum quality to show results (below this, show "try again").
    static let minimumDisplayQuality: Double = 0.30
    /// Rolling analysis window in seconds.
    static let analysisWindow: Double = 15.0
    /// Seconds between analysis passes during recording.
    static let analysisInterval: Double = 3.0
    /// Maximum recording duration in seconds.
    static let maxRecordingTime: Double = 60.0
    /// Maximum plausible rate error in s/day. Above this we assume a snapping
    /// error (wrong rate chosen), which produces errors in the tens of thousands.
    /// Set generously to accommodate badly-worn movements that still run.
    static let maxPlausibleRateError: Double = 2000.0

    /// Quality color thresholds for UI display.
    static func qualityColor(_ percent: Int) -> Color {
        if percent >= 50 { return .green }
        if percent >= 30 { return .orange }
        if percent > 0 { return .red }
        return .secondary
    }
}

@MainActor
final class MeasurementCoordinator: ObservableObject {

    enum State: Equatable {
        case idle
        case monitoring
        case recording
        case analyzing
        case result(MeasurementDisplayData)
        case needsService(NeedsServiceData)
        case error(String)
    }

    /// Shown when a high-quality result is obtained but the rate error is
    /// outside the normal display range. The movement works well enough to
    /// measure confidently — it's just running far off.
    struct NeedsServiceData: Equatable {
        let rateBPH: Int
        let rateErrorSecondsPerDay: Double
    }

    struct MeasurementDisplayData: Equatable {
        let rateBPH: Int
        let rateError: Double
        let rateErrorFormatted: String
        let beatErrorMs: Double?
        let beatErrorFormatted: String?
        let qualityPercent: Int
        let tickCount: Int
        let diagnosticText: String
        let tickResiduals: [(index: Int, residualMs: Double, isEven: Bool)]
        /// Escapement pulse widths for amplitude estimation (independent of lift angle).
        let pulseWidths: PulseWidthEstimate?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rateBPH == rhs.rateBPH && lhs.rateError == rhs.rateError &&
            lhs.qualityPercent == rhs.qualityPercent && lhs.tickCount == rhs.tickCount
        }
    }

    @Published var state: State = .idle
    @Published var ratePowers: [StandardBeatRate: Float] = [:]
    @Published var rawPeak: Float = 0
    /// User-entered lift angle for amplitude calculation. Persists across sessions.
    /// Defaults to 52° (most common value used by timegraphers).
    @Published var liftAngleDegrees: Double {
        didSet { UserDefaults.standard.set(liftAngleDegrees, forKey: "liftAngleDegrees") }
    }

    /// Best quality seen so far during this recording session.
    private(set) var bestQualitySoFar: Int = 0
    /// Quality from the most recent analysis pass (may be lower than best).
    private(set) var currentQuality: Int = 0
    /// When recording started — the view uses this to compute elapsed time per frame.
    private(set) var recordingStartTime: ContinuousClock.Instant?
    /// When monitoring (listening) started — for the initial hand sweep.
    private(set) var monitoringStartTime: ContinuousClock.Instant?
    /// Guards the timer task from overwriting state after recording ends.
    private var isRecording: Bool = false
    /// True only for the first monitoring session. Drives the 11:00→12:00 sweep animation.
    /// Subsequent returns to monitoring start the hand at 12:00 with no sweep.
    private(set) var needsSweep: Bool = true

    let analysisWindow = MeasurementConstants.analysisWindow
    let qualityThreshold = MeasurementConstants.autoStopQuality
    let minimumDisplayQuality = MeasurementConstants.minimumDisplayQuality
    let analysisInterval = MeasurementConstants.analysisInterval
    let maxRecordingTime = MeasurementConstants.maxRecordingTime

    private let captureService = AudioCaptureService()
    private let frequencyMonitor = FrequencyMonitor()
    private let pipeline = MeasurementPipeline()
    private let amplitudeEstimator = AmplitudeEstimator()
    private var recordingTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    private static let defaultLiftAngle: Double = 52.0

    init() {
        let stored = UserDefaults.standard.double(forKey: "liftAngleDegrees")
        self.liftAngleDegrees = stored > 0 ? stored : Self.defaultLiftAngle
    }

    // MARK: - Lifecycle

    /// Called when the app moves to the background. Stops audio capture
    /// and returns to idle so the mic is released.
    func handleBackgrounded() {
        switch state {
        case .monitoring:
            stopMonitoring()
        case .recording:
            cancelMeasurement()
        default:
            break
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        do {
            ratePowers = [:]
            try frequencyMonitor.start()
            state = .monitoring
            monitoringStartTime = ContinuousClock.now
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
        needsSweep = false
        state = .idle
        ratePowers = [:]
    }

    // MARK: - Recording

    func startMeasurement() {
        // Cancel the monitoring poll task, but don't call frequencyMonitor.stop()
        // which would clear the buffer. initializeForExternalFeed() will stop
        // the engine but preserve the buffer for seamless bars.
        monitorTask?.cancel()
        monitorTask = nil
        needsSweep = false
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
        let granted = await captureService.requestPermission()
        guard granted else {
            state = .error("Microphone access denied.")
            return
        }

        frequencyMonitor.initializeForExternalFeed(sampleRate: 48000)
        captureService.onSamples = { [weak self] samples in
            self?.frequencyMonitor.feedSamples(samples)
        }

        do {
            await captureService.resetBuffer()
            try captureService.startRecording()
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        state = .recording
        bestQualitySoFar = 0
        currentQuality = 0
        isRecording = true

        let startTime = ContinuousClock.now
        recordingStartTime = startTime
        let maxRate = MeasurementConstants.maxPlausibleRateError
        var bestResult: (MeasurementResult, PipelineDiagnostics, WatchBeatCore.AudioBuffer)?
        var bestQuality: Double = 0

        // Timer task: updates frequency bars every 200ms.
        // Does NOT update state — the view uses TimelineView to read elapsed time
        // directly from recordingStartTime at 60fps.
        monitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard self.isRecording else { break }
                self.ratePowers = self.frequencyMonitor.ratePowers
            }
        }

        // Wait for enough audio
        while !Task.isCancelled {
            let elapsed = (ContinuousClock.now - startTime).asSeconds
            if elapsed >= analysisWindow || elapsed > maxRecordingTime { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        // Analysis loop
        while !Task.isCancelled {
            let elapsed = (ContinuousClock.now - startTime).asSeconds
            if elapsed > maxRecordingTime { break }

            if let buffer = await captureService.getRecentAudio(duration: analysisWindow) {
                let (result, diagnostics) = await Task.detached { [pipeline] in
                    pipeline.measureWithDiagnostics(buffer)
                }.value

                let quality = result.qualityScore
                currentQuality = Int(quality * 100)
                bestQualitySoFar = max(bestQualitySoFar, currentQuality)

                if quality > bestQuality {
                    bestQuality = quality
                    bestResult = (result, diagnostics, buffer)
                }

                // Auto-stop on high quality regardless of rate plausibility.
                // A 100%-quality result won't improve by running longer; if the
                // watch is genuinely running far off, the post-loop maxRate
                // check routes to the needs-service screen.
                if quality >= qualityThreshold {
                    break
                }
            }

            try? await Task.sleep(for: .seconds(analysisInterval))
        }

        // Stop the timer from updating state, THEN cancel it
        isRecording = false
        monitorTask?.cancel()
        monitorTask = nil

        captureService.stopRecording()

        guard !Task.isCancelled else {
            state = .idle
            return
        }

        // Three outcomes: implausibly-far-off (high quality but rate out of range),
        // signal-too-weak (never got a usable fit), or a normal result.
        guard let (result, diagnostics, audioBuffer) = bestResult,
              result.qualityScore >= minimumDisplayQuality else {
            if let (r, _, buf) = bestResult {
                saveRawAudio(buf, result: r)
            }
            let q = Int((bestResult?.0.qualityScore ?? 0) * 100)
            let sr = Int(captureService.sampleRate)
            let peak = String(format: "%.3f", bestResult?.1.rawPeakAmplitude ?? 0)
            state = .error("Could not get a clear enough signal. Press the phone firmly against the caseback in a quiet room and watch for the frequency bars.\n\nDiag: q=\(q)% sr=\(sr)Hz peak=\(peak) mic=\(captureService.lastConfigInfo)")
            return
        }

        saveRawAudio(audioBuffer, result: result)

        // Snap-confusion: the tick regression's measured rate disagrees sharply
        // with the chosen standard rate. Adjacent standard rates differ by 10-20%,
        // so a >7% mismatch means we locked onto the wrong rate. A badly-worn but
        // correctly-identified watch only drifts a few percent (2000 s/day ≈ 2.3%).
        let measuredOscHz = diagnostics.periodEstimate.measuredHz / 2.0
        let snappedOscHz = result.snappedRate.oscillationHz
        if abs(measuredOscHz - snappedOscHz) / snappedOscHz > 0.07 {
            let hzStr = String(format: "%.2f", measuredOscHz)
            state = .error("Measuring \(hzStr) Hz, but that doesn't seem right. If you know the watch's beat rate, check whether this matches. Otherwise try repositioning the phone against the caseback.")
            return
        }

        if abs(result.rateErrorSecondsPerDay) > maxRate {
            state = .needsService(NeedsServiceData(
                rateBPH: result.snappedRate.rawValue,
                rateErrorSecondsPerDay: result.rateErrorSecondsPerDay
            ))
            return
        }

        let pulseWidths = await Task.detached { [amplitudeEstimator] in
            amplitudeEstimator.measurePulseWidths(
                input: audioBuffer,
                rate: result.snappedRate,
                rateErrorSecondsPerDay: result.rateErrorSecondsPerDay,
                tickTimings: result.amplitudeTickTimings
            )
        }.value

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
            tickResiduals: tickResiduals,
            pulseWidths: pulseWidths
        )
        state = .result(displayData)
    }

    // MARK: - File saving (disabled, call from performContinuousMeasurement to re-enable)

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

extension Duration {
    var asSeconds: Double {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
