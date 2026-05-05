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

    // MARK: - Routing & scoring thresholds
    //
    // All gates the recording loop and routing ladder evaluate, in one
    // place. Numbers here read like a spec; routing code reads as
    // intent rather than as arithmetic.

    /// Auto-stop also requires confirmedFraction at or above this — high
    /// SNR alone isn't enough to declare success; we need most beat windows
    /// to have shown a real tick.
    static let autoStopConfirmedFraction: Double = 0.80

    /// Best-window selection bonus: any candidate window that confirmed
    /// at least this fraction of beats earns a trust bonus over those
    /// that didn't, even at lower raw quality.
    static let bestWindowConfirmedTrustThreshold: Double = 0.5

    /// Weak Signal gate: minimum confirmedFraction. Below this we treat
    /// the recording as "too few real ticks to measure" regardless of SNR.
    static let weakSignalMinConfirmedFraction: Double = 0.5

    /// Weak Signal gate: minimum tickTimings count after outlier rejection.
    /// 3 is the absolute floor where the timegraph is even drawable; below
    /// that we have no per-tick evidence to display.
    static let weakSignalMinTickCount: Int = 3

    /// Snap Confusion gate: maximum allowed |measured − snapped| / snapped.
    /// Adjacent standard rates differ by ≥10%, so 7% mismatch reliably
    /// indicates we locked onto something off-grid (harmonic, sub-event).
    static let snapConfusionMaxFractionalDeviation: Double = 0.07

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
        case weakSignal(diagnostic: String)
        case lowAnalyticalConfidence
        case quartzDetected
        case micUnavailable(diagnostic: String?)
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
        let tickTimings: [TickTiming]
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
    /// Pipeline injected via init for testability — production passes
    /// MeasurementPipeline (default), tests can pass a mock that returns
    /// canned results.
    private let pipeline: BeatPicker
    /// Amplitude estimator injected via init for the same reason.
    private let amplitudeEstimator: AmplitudeMeasuring
    private let orientationMonitor = OrientationMonitor()
    private var recordingTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    // 50° is the dominant cluster for modern Swiss/Japanese automatics
    // (ETA 2824/2892/7750, Sellita SW200, Omega 8500/8800/1120, Rolex
    // 3135, JLC 899). Most likely correct value out of the box for the
    // largest user group; vintage and pin-lever owners adjust manually.
    private static let defaultLiftAngle: Double = 50.0

    init(pipeline: BeatPicker = MeasurementPipeline(),
         amplitudeEstimator: AmplitudeMeasuring = AmplitudeEstimator()) {
        self.pipeline = pipeline
        self.amplitudeEstimator = amplitudeEstimator
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
                self.state = .micUnavailable(diagnostic: nil)
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
                self.state = .micUnavailable(diagnostic: "Could not start audio: \(error.localizedDescription)")
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

        // Run the analysis loop in a dedicated session. Returns the
        // best-scoring window across the 60 s budget (or nil if cancelled
        // / timed out before any window completed).
        let session = RecordingSession(
            captureService: captureService,
            pipeline: pipeline,
            analysisWindow: analysisWindow,
            analysisInterval: analysisInterval,
            maxRecordingTime: maxRecordingTime,
            qualityThreshold: qualityThreshold,
            startTime: startTime,
            progressHandler: { [weak self] current, best in
                self?.currentQuality = current
                self?.bestQualitySoFar = best
            }
        )
        let bestWindow = await session.run()

        // Stop the live-bar timer, THEN cancel it.
        isRecording = false
        monitorTask?.cancel()
        monitorTask = nil

        captureService.onSamples = nil
        captureService.stopRecording()

        // Capture a position snapshot now, while the orientation monitor is
        // still running, then tear it down. We only need to query it once.
        let windowPosition: WatchPosition? = {
            guard let endTime = bestWindow?.endTime else { return nil }
            return orientationMonitor.position(endingAt: endTime,
                                               duration: analysisWindow)
        }()
        orientationMonitor.stop()

        guard !Task.isCancelled else {
            state = .idle
            return
        }

        let bestResult = bestWindow?.result
        let bestDiagnostics = bestWindow?.diagnostics
        let bestBuffer = bestWindow?.buffer

        // Save raw audio in DEBUG builds only — for support / corpus
        // building during development. Production / TestFlight / App Store
        // builds never save audio: the privacy promise in the listing
        // ("microphone audio is never saved to disk") is enforced at
        // compile time. Recordings are accessible from a DEBUG build via
        // Xcode's Devices & Simulators → installed-app container browser.
        #if DEBUG
        if let r = bestResult, let buf = bestBuffer {
            saveRawAudio(buf, result: r)
        }
        #endif

        let decision = Router.classify(
            bestResult: bestResult,
            diagnostics: bestDiagnostics,
            weakSignalContext: Router.WeakSignalContext(
                sampleRate: Int(captureService.sampleRate),
                micConfig: captureService.lastConfigInfo
            ),
            maxPlausibleRateError: maxRate
        )

        switch decision {
        case .weakSignal(let diag):
            // Before showing Weak Signal, check whether the recording
            // looks like a quartz watch. The main pipeline only sees
            // post-5-kHz-HP signal which strips most quartz energy, so
            // this fallback runs on the raw audio looking for the
            // 1-Hz-harmonic-comb signature of a quartz watch's once-per-
            // second click. If found, show the (more useful) Quartz
            // Detected screen instead of generic Weak Signal.
            if let buf = bestBuffer,
               MeasurementPipeline.detectQuartz(rawSamples: buf.samples, sampleRate: buf.sampleRate) {
                state = .quartzDetected
            } else {
                state = .weakSignal(diagnostic: diag)
            }
        case .lowAnalyticalConfidence:
            state = .lowAnalyticalConfidence
        case .quartzDetected:
            state = .quartzDetected
        case .rateConfusion(let data):
            state = .rateConfusion(data)
        case .needsService(let data):
            state = .needsService(data)
        case .displayResult:
            // Router guarantees bestResult, bestDiagnostics, bestBuffer are
            // non-nil when it returns .displayResult.
            guard let result = bestResult,
                  let diagnostics = bestDiagnostics,
                  let audioBuffer = bestBuffer else { return }
            await displayResult(result: result,
                                diagnostics: diagnostics,
                                audioBuffer: audioBuffer,
                                windowPosition: windowPosition)
        }
    }

    /// Build a display payload for the .result state. Computes pulse widths
    /// off-main-actor (amplitude estimation is non-trivial work) and
    /// formats the diagnostic blob the result page may surface for support.
    private func displayResult(
        result: MeasurementResult,
        diagnostics: PipelineDiagnostics,
        audioBuffer: WatchBeatCore.AudioBuffer,
        windowPosition: WatchPosition?
    ) async {
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

        let displayData = MeasurementDisplayData(
            rateBPH: result.snappedRate.rawValue,
            rateError: result.rateErrorSecondsPerDay,
            rateErrorFormatted: formatRateError(result.rateErrorSecondsPerDay),
            beatErrorMs: result.beatErrorMilliseconds,
            beatErrorFormatted: result.beatErrorMilliseconds.map { formatBeatError($0) },
            qualityPercent: MeasurementConstants.displayedQuality(result),
            tickCount: result.tickCount,
            diagnosticText: diagText,
            tickTimings: result.tickTimings,
            pulseWidths: pulseWidths,
            isLowConfidence: result.isLowConfidence,
            watchPosition: windowPosition
        )
        state = .result(displayData)
    }

    // MARK: - File saving (DEBUG-only diagnostic — call site gated above)

    #if DEBUG
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
    #endif

    private func formatRateError(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(Int(value.rounded())) s/day"
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
