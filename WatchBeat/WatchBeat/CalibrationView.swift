import SwiftUI
import AVFoundation

/// One-shot calibration tool that measures the iPhone's audio sample
/// clock against an external NTP server.
///
/// Background: the iPhone's audio path runs at a nominal sample rate
/// (44100 or 48000 Hz) but the actual frequency is set by a crystal that
/// is offset from nominal by some unknown ppm. That offset shows up as
/// a constant multiplicative bias in every WatchBeat rate measurement.
/// Comparison with the timegrapher cluster suggested an offset on the
/// order of 41 s/day = 475 ppm — enough to be the dominant rate-error
/// contributor.
///
/// This tool measures that offset directly. It runs `AVAudioEngine` for
/// a long interval (default 10 minutes) and queries an NTP server twice:
/// once at the start, once at the end. The audio sample clock's elapsed
/// time is compared to NTP-anchored elapsed time; the ratio gives the
/// crystal's ppm offset.
///
/// Sub-shifts handled:
///   * Audio engine `lastRenderTime.hostTime` is in mach time units —
///     convertible to seconds via mach_timebase_info. Same units as the
///     `monotonicSeconds()` helper used for SNTP query timestamps.
///   * Audio engine sample times are tied to the audio crystal; mach
///     host time tracks the system clock. Difference between the two,
///     scaled by interval length, is the audio crystal's offset from
///     nominal.
///   * NTP gives true wall time. Comparing audio elapsed to NTP elapsed
///     directly measures the audio crystal vs. truth.
struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var startEpoch: Double = 0       // unix seconds at start
    @State private var startAudioSec: Double = 0    // audio sample-clock seconds at start
    @State private var startMonoSec: Double = 0     // monotonic seconds at start
    @State private var startRTT: Double = 0
    @State private var elapsedSec: Double = 0
    @State private var resultPPM: Double? = nil
    @State private var resultDetails: String = ""
    @State private var errorMessage: String? = nil

    @State private var engine: AVAudioEngine?
    @State private var timer: Timer?
    @State private var startedAt: Date = .now

    private let durationSec: Double = 600   // 10 minutes
    private let ntpHost: String = "time.apple.com"

    enum Phase {
        case idle, starting, running, finalizing, done, error
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Audio Clock Calibration")
                    .font(.title2.bold())
                    .padding(.top)

                Text(statusText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if phase == .running {
                    ProgressView(value: elapsedSec, total: durationSec)
                        .padding(.horizontal, 40)
                    Text(timeRemainingText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let ppm = resultPPM, phase == .done {
                    VStack(spacing: 8) {
                        Text(String(format: "%+.1f ppm", ppm))
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                        Text(String(format: "= %+.1f s/day correction",
                                    -ppm / 1e6 * 86400))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(resultDetails)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                if phase == .idle || phase == .done || phase == .error {
                    Button(action: startCalibration) {
                        Text(phase == .done ? "Run Again" : "Start Calibration (10 min)")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }

                Button("Close", action: { stopAndDismiss() })
                    .padding(.bottom)
            }
        }
    }

    private var statusText: String {
        switch phase {
        case .idle: return "Compares the iPhone's audio sample clock against an NTP server. Run plugged in, in foreground, on a stable network."
        case .starting: return "Querying NTP and starting audio engine..."
        case .running: return "Measuring..."
        case .finalizing: return "Final NTP query..."
        case .done: return "Calibration complete."
        case .error: return "Calibration failed."
        }
    }

    private var timeRemainingText: String {
        let remaining = max(0, durationSec - elapsedSec)
        let m = Int(remaining) / 60
        let s = Int(remaining) % 60
        return String(format: "%02d:%02d remaining", m, s)
    }

    // MARK: - Calibration steps

    private func startCalibration() {
        errorMessage = nil
        resultPPM = nil
        resultDetails = ""
        phase = .starting

        // 1. Configure and start audio engine.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [])
            try session.setActive(true)
            let eng = AVAudioEngine()
            // Connect input → main mixer to keep engine running with input
            // permission. We don't tap or read any samples — we only need
            // the engine's render clock to advance.
            let input = eng.inputNode
            _ = input.outputFormat(forBus: 0)
            try eng.start()
            self.engine = eng
        } catch {
            phase = .error
            errorMessage = "Audio engine start failed: \(error.localizedDescription)"
            return
        }

        // 2. Initial NTP query.
        ntpQuery(host: ntpHost) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    phase = .error
                    errorMessage = "Initial NTP query failed: \(err)"
                    self.engine?.stop()
                    self.engine = nil
                    return
                case .success(let r):
                    // Record anchor.
                    let audioSec = currentAudioSampleSeconds(engine: self.engine)
                    self.startEpoch = r.serverTime + (currentMonotonicSeconds() - r.clientReceiveTime)
                    self.startAudioSec = audioSec
                    self.startMonoSec = currentMonotonicSeconds()
                    self.startRTT = r.roundTripSeconds
                    self.startedAt = .now
                    self.phase = .running
                    self.startProgressTimer()
                }
            }
        }
    }

    private func startProgressTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsedSec = currentMonotonicSeconds() - startMonoSec
            if elapsedSec >= durationSec {
                timer?.invalidate(); timer = nil
                finalize()
            }
        }
    }

    private func finalize() {
        phase = .finalizing
        ntpQuery(host: ntpHost) { result in
            DispatchQueue.main.async {
                guard let eng = self.engine else {
                    phase = .error
                    errorMessage = "Engine vanished before final query."
                    return
                }
                switch result {
                case .failure(let err):
                    phase = .error
                    errorMessage = "Final NTP query failed: \(err)"
                    eng.stop(); self.engine = nil
                    return
                case .success(let r):
                    let endAudioSec = currentAudioSampleSeconds(engine: eng)
                    let endMonoSec = currentMonotonicSeconds()
                    let endEpoch = r.serverTime + (endMonoSec - r.clientReceiveTime)

                    let audioElapsed = endAudioSec - startAudioSec
                    let trueElapsed = endEpoch - startEpoch
                    let monoElapsed = endMonoSec - startMonoSec

                    // ppm = (audio_elapsed / true_elapsed - 1) * 1e6
                    // If audio runs FAST (audio_elapsed > true_elapsed), ppm > 0.
                    let ppm = (audioElapsed / trueElapsed - 1.0) * 1e6
                    let monoPPM = (monoElapsed / trueElapsed - 1.0) * 1e6

                    // Uncertainty: (RTT_start + RTT_end) / 2 / true_elapsed.
                    let unc = (startRTT + r.roundTripSeconds) * 0.5 / trueElapsed * 1e6

                    self.resultPPM = ppm
                    self.resultDetails = String(
                        format: """
                        audio elapsed: %.4f s
                        NTP   elapsed: %.4f s
                        mono  elapsed: %.4f s
                        audio − NTP:   %+.1f ms
                        host  − NTP:   %+.1f ms (system clock)
                        RTT start/end: %.0f / %.0f ms
                        uncertainty:   ±%.1f ppm
                        """,
                        audioElapsed, trueElapsed, monoElapsed,
                        (audioElapsed - trueElapsed) * 1000,
                        (monoElapsed - trueElapsed) * 1000,
                        startRTT * 1000, r.roundTripSeconds * 1000,
                        unc
                    )
                    _ = monoPPM   // available in details; kept for future logging
                    eng.stop(); self.engine = nil
                    phase = .done
                }
            }
        }
    }

    private func stopAndDismiss() {
        timer?.invalidate(); timer = nil
        engine?.stop(); engine = nil
        dismiss()
    }
}

// MARK: - Sample-clock helpers

/// Returns the audio sample clock's current time, in seconds, derived
/// from the engine's lastRenderTime (which has both sampleTime and
/// hostTime fields). We use sampleTime / sampleRate — the canonical
/// audio-crystal-driven clock.
fileprivate func currentAudioSampleSeconds(engine: AVAudioEngine?) -> Double {
    guard let eng = engine else { return 0 }
    guard let lastRender = eng.outputNode.lastRenderTime else { return 0 }
    let sr = lastRender.sampleRate
    if sr > 0 {
        return Double(lastRender.sampleTime) / sr
    }
    return 0
}

/// Helper duplicating monotonicSeconds() from NTPClient.swift. Kept
/// here to allow @State access within the SwiftUI struct without
/// crossing module boundaries.
fileprivate func currentMonotonicSeconds() -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let host = mach_continuous_time()
    let nanos = Double(host) * Double(info.numer) / Double(info.denom)
    return nanos / 1e9
}
