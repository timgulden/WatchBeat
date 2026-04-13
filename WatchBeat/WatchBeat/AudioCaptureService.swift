import AVFoundation
import WatchBeatCore

/// Wraps AVAudioEngine to capture raw audio for the DSP pipeline.
///
/// Configures AVAudioSession with `.measurement` mode to disable automatic gain control,
/// noise suppression, and other voice-processing DSP that would corrupt the signal.
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

    /// Request microphone permission. Returns true if granted.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Capture audio for the specified duration and return a buffer suitable for the DSP pipeline.
    ///
    /// - Parameter duration: Recording duration in seconds.
    /// - Returns: An `AudioBuffer` with Float samples at the hardware sample rate.
    func capture(duration: Double) async throws -> WatchBeatCore.AudioBuffer {
        // Configure audio session for measurement (no AGC, no noise suppression)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
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

        // Use an actor to safely collect samples from the audio callback
        let collector = SampleCollector(expectedSamples: expectedSamples)
        let bufferSize: AVAudioFrameCount = 4096

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            let channelData = buffer.floatChannelData?[0]
            let frameCount = Int(buffer.frameLength)
            if let data = channelData {
                let samples = Array(UnsafeBufferPointer(start: data, count: frameCount))
                Task { await collector.append(samples) }
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }

        // Wait for samples to accumulate, with a timeout
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
