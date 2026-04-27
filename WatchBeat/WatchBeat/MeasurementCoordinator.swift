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
    /// Duration of the 12:00→1:00 listening sweep while the 5 s rolling buffer
    /// fills. Measure button is disabled until the sweep completes.
    static let listenSweepDuration: Double = 5.0
    /// Maximum duration of the post-Measure recording phase (1:00→12:00).
    /// Combined with `listenSweepDuration` this matches the 60 s wheel cycle.
    static let maxRecordingTime: Double = 55.0
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
        /// True when tick/tock residuals both straddle zero — the rate and beat
        /// error should be interpreted with caution (and may be wrong outright).
        let isDisorderly: Bool
        /// Watch position held throughout the analysis window that produced
        /// this result, or nil if the phone moved between positions during
        /// that window (in which case no position is displayed).
        let watchPosition: WatchPosition?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rateBPH == rhs.rateBPH && lhs.rateError == rhs.rateError &&
            lhs.qualityPercent == rhs.qualityPercent && lhs.tickCount == rhs.tickCount
        }
    }

    @Published var state: State = .idle
    @Published var ratePowers: [StandardBeatRate: Float] = [:]
    @Published var rawPeak: Float = 0
    /// Live watch position (from accelerometer). Nil while the phone is
    /// between positions or motion isn't running.
    @Published var currentPosition: WatchPosition?
    /// Counter-rotation (degrees) to apply to the Listening/Measuring content
    /// so it reads upright regardless of phone pose. Latched: only updates
    /// when a new unambiguous position arrives — intermediate nil states
    /// hold the last confirmed rotation to avoid snap-backs during transits.
    @Published var latchedUIRotation: Double = 0
    /// User-entered lift angle for amplitude calculation. Persists across sessions.
    /// Defaults to 52° (most common value used by timegraphers).
    @Published var liftAngleDegrees: Double {
        didSet { UserDefaults.standard.set(liftAngleDegrees, forKey: "liftAngleDegrees") }
    }

    /// Best quality seen so far during this recording session.
    private(set) var bestQualitySoFar: Int = 0
    /// Quality from the most recent analysis pass (may be lower than best).
    private(set) var currentQuality: Int = 0
    /// When recording started (user pressed Measure) — drives the post-Measure wheel sweep.
    private(set) var recordingStartTime: ContinuousClock.Instant?
    /// When monitoring (listening) started — drives the 12:00→1:00 buffer-fill sweep.
    private(set) var monitoringStartTime: ContinuousClock.Instant?
    /// Guards the timer task from overwriting state after recording ends.
    private var isRecording: Bool = false

    let analysisWindow = MeasurementConstants.analysisWindow
    let qualityThreshold = MeasurementConstants.autoStopQuality
    let minimumDisplayQuality = MeasurementConstants.minimumDisplayQuality
    let analysisInterval = MeasurementConstants.analysisInterval
    let maxRecordingTime = MeasurementConstants.maxRecordingTime

    private let captureService = AudioCaptureService()
    private let frequencyMonitor = FrequencyMonitor()
    private let pipeline = MeasurementPipeline()
    private let amplitudeEstimator = AmplitudeEstimator()
    private let orientationMonitor = OrientationMonitor()
    private var recordingTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    private static let defaultLiftAngle: Double = 52.0

    init() {
        let stored = UserDefaults.standard.double(forKey: "liftAngleDegrees")
        self.liftAngleDegrees = stored > 0 ? stored : Self.defaultLiftAngle
        orientationMonitor.onPositionChange = { [weak self] pos in
            self?.currentPosition = pos
        }
        orientationMonitor.onClosestPositionChange = { [weak self] closest in
            self?.latchedUIRotation = Self.rotation(for: closest)
        }
    }

    /// Map a watch position to the counter-rotation needed so UI reads
    /// upright. Both flat poses (face-up, face-down) keep portrait since
    /// gravity along ±Z gives no meaningful "up" direction for the viewer.
    private static func rotation(for position: WatchPosition) -> Double {
        switch position {
        case .dialDown, .twelveUp, .sixUp: return 0
        case .dialUp:    return 180
        case .crownUp:   return -90
        case .crownDown: return  90
        }
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

    /// Start listening. AudioCaptureService owns the mic and feeds the
    /// FrequencyMonitor via its external-feed path, so there is a single
    /// audio engine across listening + measuring — buffer carries over.
    func startMonitoring() {
        ratePowers = [:]
        state = .monitoring
        monitoringStartTime = ContinuousClock.now
        orientationMonitor.start()

        Task { [weak self] in
            guard let self else { return }
            let granted = await self.captureService.requestPermission()
            guard granted else {
                self.state = .error("Microphone access denied.")
                return
            }
            // Fresh buffer on every entry — the previous session's tail is not
            // part of this new listen.
            await self.captureService.resetBuffer()
            self.frequencyMonitor.initializeForExternalFeed(sampleRate: self.captureService.sampleRate)
            self.captureService.onSamples = { [weak self] samples in
                self?.frequencyMonitor.feedSamples(samples)
            }
            do {
                try self.captureService.startRecording()
            } catch {
                self.state = .error("Could not start audio: \(error.localizedDescription)")
                return
            }
            // Re-init with the real sample rate now that the engine is up.
            self.frequencyMonitor.initializeForExternalFeed(sampleRate: self.captureService.sampleRate)

            self.monitorTask?.cancel()
            self.monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self else { break }
                    self.ratePowers = self.frequencyMonitor.ratePowers
                    self.rawPeak = self.frequencyMonitor.rawPeak
                }
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        captureService.onSamples = nil
        captureService.stopRecording()
        orientationMonitor.stop()
        state = .idle
        ratePowers = [:]
    }

    // MARK: - Recording

    /// User pressed Measure. Capture is already running from the listening
    /// phase — just transition state and begin the analysis loop. The buffer
    /// already holds the pre-Measure listening audio so the first 15 s window
    /// becomes available roughly 10 s after this call.
    func startMeasurement() {
        recordingTask?.cancel()
        recordingTask = Task { await performContinuousMeasurement() }
    }

    func cancelMeasurement() {
        recordingTask?.cancel()
        recordingTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        captureService.onSamples = nil
        captureService.stopRecording()
        orientationMonitor.stop()
        state = .idle
        ratePowers = [:]
    }

    private func performContinuousMeasurement() async {
        // Capture is already running from monitoring — keep the mic hot but
        // discard the Buffering audio. The 5 s buffer let the user dial in
        // placement; the real sample starts fresh at Measure press so the
        // first 15 s analysis completes at the wheel's 4:00 mark.
        await captureService.resetBuffer()
        state = .recording
        bestQualitySoFar = 0
        currentQuality = 0
        isRecording = true

        let startTime = ContinuousClock.now
        recordingStartTime = startTime
        let maxRate = MeasurementConstants.maxPlausibleRateError
        var bestResult: (MeasurementResult, PipelineDiagnostics, WatchBeatCore.AudioBuffer, ContinuousClock.Instant)?
        var bestQuality: Double = 0

        // Keep the bars live during recording. Polls frequencyMonitor's
        // rate powers at ~5 Hz; the view reads elapsed time via TimelineView.
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.isRecording else { break }
                self.ratePowers = self.frequencyMonitor.ratePowers
            }
        }

        // Wait until the buffer holds a full analysis window.
        while !Task.isCancelled {
            let elapsed = (ContinuousClock.now - startTime).asSeconds
            if elapsed > maxRecordingTime { break }
            let secs = await captureService.secondsCollected()
            if secs >= analysisWindow { break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Analysis loop — hard stop at exactly maxRecordingTime.
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
                    // Stamp the moment this analysis window ended so we can
                    // later ask the orientation monitor whether the phone
                    // stayed in one position across its 15-second span.
                    bestResult = (result, diagnostics, buffer, ContinuousClock.now)
                }

                // Auto-stop on high quality regardless of rate plausibility.
                // A 100%-quality result won't improve by running longer; if the
                // watch is genuinely running far off, the post-loop maxRate
                // check routes to the needs-service screen.
                if quality >= qualityThreshold {
                    break
                }
            }

            // Sleep until next analysis, capped by remaining budget so we
            // never overshoot the hard stop.
            let remaining = maxRecordingTime - (ContinuousClock.now - startTime).asSeconds
            let sleepSec = min(analysisInterval, max(0.05, remaining))
            try? await Task.sleep(for: .seconds(sleepSec))
        }

        // Stop the timer from updating state, THEN cancel it
        isRecording = false
        monitorTask?.cancel()
        monitorTask = nil

        captureService.onSamples = nil
        captureService.stopRecording()

        // Capture a position snapshot now, while the orientation monitor is
        // still running, then tear it down. We only need to query it once.
        let windowPosition: WatchPosition? = {
            guard let (_, _, _, windowEnd) = bestResult else { return nil }
            return orientationMonitor.position(endingAt: windowEnd,
                                               duration: analysisWindow)
        }()
        orientationMonitor.stop()

        guard !Task.isCancelled else {
            state = .idle
            return
        }

        // Three outcomes: implausibly-far-off (high quality but rate out of range),
        // signal-too-weak (never got a usable fit), or a normal result.
        guard let (result, diagnostics, audioBuffer, _) = bestResult,
              result.qualityScore >= minimumDisplayQuality else {
            // Disabled for release — uncomment to capture failed-measurement audio for analysis.
            // if let (r, _, buf, _) = bestResult {
            //     saveRawAudio(buf, result: r)
            // }
            let q = Int((bestResult?.0.qualityScore ?? 0) * 100)
            let sr = Int(captureService.sampleRate)
            let peak = String(format: "%.3f", bestResult?.1.rawPeakAmplitude ?? 0)
            state = .error("Could not get a clear enough signal. Press the phone firmly against the caseback in a quiet room and watch for the frequency bars.\n\nDiag: q=\(q)% sr=\(sr)Hz peak=\(peak) mic=\(captureService.lastConfigInfo)")
            return
        }

        // Disabled for release — uncomment to capture successful-measurement audio for analysis.
        // saveRawAudio(audioBuffer, result: result)

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
            pulseWidths: pulseWidths,
            isDisorderly: result.isDisorderly,
            watchPosition: windowPosition
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
