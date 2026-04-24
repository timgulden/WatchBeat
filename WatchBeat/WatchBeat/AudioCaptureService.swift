import AVFoundation
import WatchBeatCore

/// Configures the audio session optimally for recording watch ticks.
enum AudioSessionConfigurator {
    @discardableResult
    static func configure() throws -> String {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)

        var info = "Mode: measurement"

        // Prefer a plugged-in external mic (wired headset, USB/Lightning audio,
        // line-in) over the built-in mic. Bluetooth HFP is excluded — its 8 kHz
        // compressed audio is unusable for tick DSP.
        let externalTypes: [AVAudioSession.Port] = [.headsetMic, .usbAudio, .lineIn]
        let inputs = session.availableInputs ?? []

        if let external = inputs.first(where: { externalTypes.contains($0.portType) }) {
            try session.setPreferredInput(external)
            info += ", Mic: \(external.portName)"
        } else if let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
            if let bottomSource = builtInMic.dataSources?.first(where: { $0.orientation == .bottom }) {
                try builtInMic.setPreferredDataSource(bottomSource)
                info += ", Mic: bottom"
                if let patterns = bottomSource.supportedPolarPatterns, patterns.contains(.omnidirectional) {
                    try bottomSource.setPreferredPolarPattern(.omnidirectional)
                    info += " (omni)"
                }
            }
            try session.setPreferredInput(builtInMic)
        }

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

/// Captures audio continuously, providing access to the most recent N seconds
/// for rolling analysis.
final class AudioCaptureService: @unchecked Sendable {

    enum CaptureError: Error, LocalizedError {
        case sessionConfigurationFailed(Error)
        case engineStartFailed(Error)
        case noAudioCaptured

        var errorDescription: String? {
            switch self {
            case .sessionConfigurationFailed(let error):
                return "Audio session setup failed: \(error.localizedDescription)"
            case .engineStartFailed(let error):
                return "Could not start audio capture: \(error.localizedDescription)"
            case .noAudioCaptured:
                return "No audio was captured."
            }
        }
    }

    private(set) var lastConfigInfo: String = ""
    var onSamples: (([Float]) -> Void)?

    private var engine: AVAudioEngine?
    private let collector = RollingCollector()
    private(set) var sampleRate: Double = 48000

    deinit {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
    }

    /// Request microphone permission.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Start continuous recording.
    func startRecording() throws {
        lastConfigInfo = try AudioSessionConfigurator.configure()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // Belt-and-suspenders: some routes (notably wired headset mics) leave
        // AGC/noise-suppression enabled even with AVAudioSession mode .measurement.
        // Envelope shape survives it, but individual tick transients get smeared,
        // which tanks regression quality.
        try? inputNode.setVoiceProcessingEnabled(false)
        let format = inputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        guard sampleRate > 0 else {
            throw CaptureError.sessionConfigurationFailed(
                NSError(domain: "AudioCaptureService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Sample rate is 0"]))
        }

        let onSamplesCallback = self.onSamples
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: data, count: count))
            Task { await self?.collector.append(samples) }
            onSamplesCallback?(samples)
        }

        try engine.start()
        self.engine = engine
    }

    /// Stop recording and release the audio session so the mic indicator turns off.
    func stopRecording() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Get the most recent `duration` seconds of audio. Returns nil if not enough collected.
    func getRecentAudio(duration: Double) async -> WatchBeatCore.AudioBuffer? {
        let needed = Int(duration * sampleRate)
        let samples = await collector.getRecent(count: needed)
        guard samples.count >= needed else { return nil }
        return WatchBeatCore.AudioBuffer(samples: samples, sampleRate: sampleRate)
    }

    /// Get all collected audio.
    func getAllAudio() async -> WatchBeatCore.AudioBuffer {
        let samples = await collector.getAll()
        return WatchBeatCore.AudioBuffer(samples: samples, sampleRate: sampleRate)
    }

    /// Total seconds of audio collected so far.
    func secondsCollected() async -> Double {
        Double(await collector.count) / sampleRate
    }

    /// Reset the buffer (for starting a new measurement).
    func resetBuffer() async {
        await collector.reset()
    }
}

/// Thread-safe rolling sample buffer.
private actor RollingCollector {
    // Keep up to 60 seconds at 48 kHz
    private let maxSamples = 48000 * 60
    private var samples: [Float] = []

    var count: Int { samples.count }

    func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
        // Trim if over max
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    func getRecent(count: Int) -> [Float] {
        guard count <= samples.count else { return samples }
        return Array(samples.suffix(count))
    }

    func getAll() -> [Float] { samples }

    func reset() { samples.removeAll() }
}
