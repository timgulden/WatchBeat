import AVFoundation
import WatchBeatCore

/// Configures the audio session optimally for recording watch ticks.
///
/// - Selects the bottom microphone explicitly (`.lower` orientation data source)
/// - Sets input gain to maximum for quiet mechanical/quartz signals
/// - Uses `.measurement` mode to disable AGC, noise suppression, and echo cancellation
/// - Sets omnidirectional polar pattern for contact-based vibration pickup
enum AudioSessionConfigurator {

    /// Configure the audio session and return a description of what was set up.
    @discardableResult
    static func configure() throws -> String {
        let session = AVAudioSession.sharedInstance()

        // Set category and mode before selecting input
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)

        var info = "Mode: measurement"

        // Select the built-in microphone
        if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            // Prefer the bottom mic (`.lower` orientation)
            if let bottomSource = builtInMic.dataSources?.first(where: { $0.orientation == .bottom }) {
                try builtInMic.setPreferredDataSource(bottomSource)
                info += ", Mic: bottom"

                // Set omnidirectional polar pattern if available
                if let patterns = bottomSource.supportedPolarPatterns, patterns.contains(.omnidirectional) {
                    try bottomSource.setPreferredPolarPattern(.omnidirectional)
                    info += " (omni)"
                }
            } else if let anySource = builtInMic.dataSources?.first {
                // Fallback: use whatever data source is available
                try builtInMic.setPreferredDataSource(anySource)
                info += ", Mic: \(anySource.orientation?.rawValue ?? "default")"
            }

            try session.setPreferredInput(builtInMic)
        } else {
            info += ", Mic: system default"
        }

        // Maximize input gain for quiet signals
        if session.isInputGainSettable {
            try session.setInputGain(1.0)
            info += ", Gain: max"
        } else {
            info += ", Gain: not settable"
        }

        info += ", Rate: \(Int(session.sampleRate)) Hz"

        return info
    }
}

/// Wraps AVAudioEngine to capture raw audio for the DSP pipeline.
final class AudioCaptureService: @unchecked Sendable {

    enum CaptureError: Error, LocalizedError {
        case microphonePermissionDenied
        case sessionConfigurationFailed(Error)
        case engineStartFailed(Error)
        case noAudioCaptured
        case timeout

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone access is required to measure your watch."
            case .sessionConfigurationFailed(let error):
                return "Audio session setup failed: \(error.localizedDescription)"
            case .engineStartFailed(let error):
                return "Could not start audio capture: \(error.localizedDescription)"
            case .noAudioCaptured:
                return "No audio was captured. Please try again."
            case .timeout:
                return "Recording timed out. Please try again."
            }
        }
    }

    /// Description of the last audio configuration applied.
    private(set) var lastConfigInfo: String = ""

    /// Request microphone permission. Returns true if granted.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Optional callback for each chunk of samples during capture (for live monitoring).
    var onSamples: (([Float]) -> Void)?

    /// Capture audio for the specified duration.
    func capture(duration: Double) async throws -> WatchBeatCore.AudioBuffer {
        do {
            lastConfigInfo = try AudioSessionConfigurator.configure()
        } catch {
            throw CaptureError.sessionConfigurationFailed(error)
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate

        guard sampleRate > 0 else {
            throw CaptureError.sessionConfigurationFailed(
                NSError(domain: "AudioCaptureService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Sample rate is 0 — no audio input available"]))
        }

        let expectedSamples = Int(duration * sampleRate)
        let collector = SampleCollector(expectedSamples: expectedSamples)
        let bufferSize: AVAudioFrameCount = 4096

        let onSamplesCallback = self.onSamples
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            let channelData = buffer.floatChannelData?[0]
            let frameCount = Int(buffer.frameLength)
            if let data = channelData {
                let samples = Array(UnsafeBufferPointer(start: data, count: frameCount))
                Task { await collector.append(samples) }
                onSamplesCallback?(samples)
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }

        let timeoutSeconds = duration + 5.0
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)

        while await collector.count < expectedSamples {
            if ContinuousClock.now >= deadline {
                engine.stop()
                inputNode.removeTap(onBus: 0)
                throw CaptureError.timeout
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        engine.stop()
        inputNode.removeTap(onBus: 0)

        let allSamples = await collector.samples
        guard !allSamples.isEmpty else {
            throw CaptureError.noAudioCaptured
        }

        return WatchBeatCore.AudioBuffer(
            samples: Array(allSamples.prefix(expectedSamples)),
            sampleRate: sampleRate
        )
    }
}

/// Provides a live audio level stream for positioning feedback.
final class AudioLevelMonitor: @unchecked Sendable {

    private var engine: AVAudioEngine?
    /// Current peak amplitude (0...1), updated ~20x/sec.
    @MainActor var level: Float = 0
    /// Description of audio configuration.
    private(set) var configInfo: String = ""

    /// Start monitoring audio level. Call `stop()` when done.
    func start() throws {
        configInfo = try AudioSessionConfigurator.configure()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var peak: Float = 0
            for i in 0..<count {
                let abs = Swift.abs(data[i])
                if abs > peak { peak = abs }
            }
            Task { @MainActor in
                self?.level = peak
            }
        }

        try engine.start()
        self.engine = engine
    }

    /// Stop monitoring.
    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }
}

/// Thread-safe sample accumulator.
private actor SampleCollector {
    let expectedSamples: Int
    private(set) var samples: [Float] = []

    var count: Int { samples.count }

    init(expectedSamples: Int) {
        self.expectedSamples = expectedSamples
        samples.reserveCapacity(expectedSamples)
    }

    func append(_ newSamples: [Float]) {
        let remaining = expectedSamples - samples.count
        guard remaining > 0 else { return }
        let toAppend = min(newSamples.count, remaining)
        samples.append(contentsOf: newSamples.prefix(toAppend))
    }
}
