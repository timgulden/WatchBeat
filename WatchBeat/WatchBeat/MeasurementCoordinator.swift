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
    /// Duration of the Measure-button gate after entering monitoring. The
    /// FrequencyMonitor uses a grow-window FFT so bars appear immediately,
    /// but resolution is too coarse to act on for the first few seconds.
    /// Below 3 s the closest standard rates (5.0 / 5.5 Hz, 18000 / 19800 bph)
    /// can't be reliably separated, so the button stays disabled.
    static let listenSweepDuration: Double = 3.0
    /// Maximum duration of the post-Measure recording phase (12:00→12:00),
    /// matching the 60 s wheel cycle.
    static let maxRecordingTime: Double = 60.0
    /// Maximum plausible rate error in s/day. Above this we assume a snapping
    /// error (wrong rate chosen), which produces errors in the tens of thousands.
    /// Set generously to accommodate badly-worn movements that still run.
    static let maxPlausibleRateError: Double = 2000.0

    /// Display-only quality percentage. Multiplies the SNR-based qualityScore
    /// by confirmedFraction so a window of pure room noise (high SNR from
    /// per-window argmax peaks but few windows passing the 2× medianGap
    /// confirmation gate) doesn't read as misleadingly high. Clean watches
    /// with confirmedFraction ≈ 1.0 are unaffected. Internal scoring (auto-
    /// stop, best-window selection, routing gates) still uses raw qualityScore.
    static func displayedQuality(_ result: MeasurementResult) -> Int {
        Int((result.qualityScore * result.confirmedFraction) * 100)
    }

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
        case rateConfusion(RateConfusionData)
        case error(String)
    }

    /// Shown when a high-quality result is obtained but the rate error is
    /// outside the normal display range. The movement works well enough to
    /// measure confidently — it's just running far off.
    struct NeedsServiceData: Equatable {
        let rateBPH: Int
        let rateErrorSecondsPerDay: Double
    }

    /// Shown when the picker locks onto a rate that doesn't match any
    /// standard mechanical rate (>7% off the snapped standard). Could be a
    /// partially-resolved harmonic, an unusual movement, or a recording
    /// that captured a non-tick periodic event.
    struct RateConfusionData: Equatable {
        let measuredOscHz: Double
        let snappedRateBPH: Int
        let snappedRateOscHz: Double
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
        /// True when matched-filter trim dropped too many ticks for a
        /// reliable result. Coordinator routes these recordings to the
        /// error screen rather than to .result, so this field is always
        /// false on a result actually shown to the user.
        let isLowConfidence: Bool
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
                    pipeline.measureReferenceWithDiagnostics(buffer)
                }.value

                let quality = result.qualityScore
                currentQuality = MeasurementConstants.displayedQuality(result)
                bestQualitySoFar = max(bestQualitySoFar, currentQuality)

                // Composite score for choosing the "best" window across the
                // 60-second budget. Trust order:
                //   confirmed AND non-lowConf  >  confirmed AND lowConf  >  unconfirmed
                // Within the same trust class, prefer higher quality.
                func score(_ r: MeasurementResult) -> Double {
                    var s = r.qualityScore
                    if r.confirmedFraction >= 0.5 { s += 1.0 }
                    if !r.isLowConfidence { s += 2.0 }
                    return s
                }
                let scoreNew = score(result)
                let scoreCur = bestResult.map { score($0.0) } ?? -1
                if scoreNew > scoreCur {
                    // Stamp the moment this analysis window ended so we can
                    // later ask the orientation monitor whether the phone
                    // stayed in one position across its 15-second span.
                    bestResult = (result, diagnostics, buffer, ContinuousClock.now)
                }

                // Auto-stop only on a fully-trustworthy window: high quality,
                // confirmed (real ticks present), AND not low-confidence
                // (picker locked on them). A high-SNR result with high
                // jitter (lowConfidence) used to break the loop early — Tim
                // wants the loop to keep sliding the window in case a
                // better one emerges. Same for a high-SNR-but-mostly-noise
                // recording (low confirmedFraction).
                if quality >= qualityThreshold
                    && result.confirmedFraction >= 0.8
                    && !result.isLowConfidence {
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

        // Routing ladder, in three orthogonal questions:
        //
        //   1. Are there enough meaningful ticks to analyze?
        //        → "Weak Signal" if no.
        //          Tests: raw qualityScore ≥ 30%, confirmedFraction ≥ 50%,
        //          tickTimings.count ≥ 3 (the timegraph's own minimum).
        //          The tickTimings check catches FFT-rate-fallback paths
        //          where σ was high enough to skip per-tick output — pure
        //          room noise lands here.
        //
        //   2. Do the ticks form a coherent pattern?
        //        → "Low Analytical Confidence" if no.
        //          Tests: isLowConfidence (high per-class σ from the
        //          pipeline). Ticks are present but timing is too erratic
        //          to read — near-stall watch territory.
        //
        //   3. Does the rate match the snapped standard cleanly?
        //        → "Snap Confusion" if not (rate disagrees by >7%).
        //          Picker locked on a non-standard rate, possibly a
        //          partially-resolved harmonic.
        //
        //   4. Is the rate within plausible spec?
        //        → "Needs Service" if |rate| > 2000 s/day.
        //          Picker is solid, rate is real, watch is just far gone.
        //
        //   5. otherwise
        //        → Result.
        //
        // Display quality (qualityScore × confirmedFraction) is cosmetic
        // only — the routing gates use raw fields so the workflow matches
        // pre-display-change behavior.
        guard let (result, diagnostics, audioBuffer, _) = bestResult,
              result.qualityScore >= minimumDisplayQuality,
              result.confirmedFraction >= 0.5,
              result.tickTimings.count >= 3 else {
            if let (r, _, buf, _) = bestResult {
                saveRawAudio(buf, result: r)
            }
            let q = Int((bestResult?.0.qualityScore ?? 0) * 100)
            let cf = Int((bestResult?.0.confirmedFraction ?? 0) * 100)
            let sr = Int(captureService.sampleRate)
            let peak = String(format: "%.3f", bestResult?.1.rawPeakAmplitude ?? 0)
            state = .error("Could not get a clear enough signal. Press the phone firmly against the caseback in a quiet room and watch for the frequency bars.\n\nDiag: q=\(q)% confirmed=\(cf)% sr=\(sr)Hz peak=\(peak) mic=\(captureService.lastConfigInfo)")
            return
        }

        saveRawAudio(audioBuffer, result: result)

        // Low-confidence check runs BEFORE the snap/rate-range checks
        // below: if the picker isn't locking consistently we shouldn't
        // blame the watch's rate. Note that confirmedFraction and
        // tickTimings.count have already passed Gate 1, so we know real
        // ticks ARE present — this is the "near-stall watch with erratic
        // timing" case, not a bad-recording case.
        if result.isLowConfidence {
            state = .error("Low analytical confidence. The watch's tick sound was too acoustically complex to lock on consistently in this position. Try a different watch position, press the phone more firmly against the caseback, or move to a quieter room.")
            return
        }

        // Snap-confusion: the tick regression's measured rate disagrees sharply
        // with the chosen standard rate. Adjacent standard rates differ by 10-20%,
        // so a >7% mismatch means we locked onto the wrong rate. A badly-worn but
        // correctly-identified watch only drifts a few percent (2000 s/day ≈ 2.3%).
        let measuredOscHz = diagnostics.periodEstimate.measuredHz / 2.0
        let snappedOscHz = result.snappedRate.oscillationHz
        if abs(measuredOscHz - snappedOscHz) / snappedOscHz > 0.07 {
            state = .rateConfusion(RateConfusionData(
                measuredOscHz: measuredOscHz,
                snappedRateBPH: result.snappedRate.rawValue,
                snappedRateOscHz: snappedOscHz
            ))
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
            qualityPercent: MeasurementConstants.displayedQuality(result),
            tickCount: result.tickCount,
            diagnosticText: diagText,
            tickResiduals: tickResiduals,
            pulseWidths: pulseWidths,
            isLowConfidence: result.isLowConfidence,
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
