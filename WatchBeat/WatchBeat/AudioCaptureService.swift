import AVFoundation
import WatchBeatCore

/// Wraps AVAudioEngine to capture raw audio for the DSP pipeline.
///
/// Configures AVAudioSession with `.measurement` mode to disable automatic gain control,
/// noise suppression, and other voice-processing DSP that would corrupt the signal.
final class AudioCaptureService {

    enum CaptureError: Error, LocalizedError {
        case microphonePermissionDenied
        case sessionConfigurationFailed(Error)
        case engineStartFailed(Error)
        case noAudioCaptured

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
            }
        }
    }

    private let engine = AVAudioEngine()

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

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate

        let expectedSamples = Int(duration * sampleRate)
        var collectedSamples = [Float]()
        collectedSamples.reserveCapacity(expectedSamples)

        // Install a tap to collect audio samples
        let bufferSize: AVAudioFrameCount = 4096

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false

            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
                guard !finished else { return }

                let channelData = buffer.floatChannelData?[0]
                let frameCount = Int(buffer.frameLength)

                if let data = channelData {
                    let remaining = expectedSamples - collectedSamples.count
                    let samplesToAppend = min(frameCount, remaining)
                    collectedSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: samplesToAppend))
                }

                if collectedSamples.count >= expectedSamples {
                    finished = true
                    self.engine.stop()
                    inputNode.removeTap(onBus: 0)

                    if collectedSamples.isEmpty {
                        continuation.resume(throwing: CaptureError.noAudioCaptured)
                    } else {
                        let buffer = WatchBeatCore.AudioBuffer(
                            samples: Array(collectedSamples.prefix(expectedSamples)),
                            sampleRate: sampleRate
                        )
                        continuation.resume(returning: buffer)
                    }
                }
            }

            do {
                try self.engine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                continuation.resume(throwing: CaptureError.engineStartFailed(error))
            }
        }
    }
}
