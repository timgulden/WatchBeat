import SwiftUI

/// One-shot calibration tool that measures the iPhone's clock crystal
/// against an external NTP server.
///
/// Background: the iPhone's audio path runs at a nominal sample rate
/// (44100 or 48000 Hz) but the actual frequency is set by a crystal that
/// is offset from nominal by some unknown ppm. Comparison with the
/// timegrapher cluster suggested ~41 s/day = ~475 ppm — enough to be
/// the dominant rate-error contributor.
///
/// On iPhone the audio sample clock and the system monotonic clock
/// (`mach_continuous_time`) are derived from the same source crystal
/// via PLL, so measuring system-clock drift directly measures the audio
/// drift too. No audio session is needed; the tool runs in the
/// foreground or background, during phone calls, on any device, with
/// no extra permissions.
///
/// Method: query NTP at t=0 and t=10min, compare elapsed `mach_continuous_time`
/// against elapsed NTP time. Ratio gives crystal ppm.
struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var startEpoch: Double = 0       // unix seconds at start
    @State private var startMonoSec: Double = 0     // monotonic seconds at start
    @State private var startRTT: Double = 0
    @State private var elapsedSec: Double = 0
    @State private var resultPPM: Double? = nil
    @State private var resultDetails: String = ""
    @State private var errorMessage: String? = nil

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
                Text("Clock Calibration")
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
        case .idle: return "Compares the iPhone's clock against an NTP server. Runs anywhere — foreground, background, on a call. Network needed at start and end only."
        case .starting: return "Querying NTP..."
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

        // Initial NTP query.
        ntpQuery(host: ntpHost) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    phase = .error
                    errorMessage = "Initial NTP query failed: \(err)"
                    return
                case .success(let r):
                    let nowMono = currentMonotonicSeconds()
                    self.startEpoch = r.serverTime + (nowMono - r.clientReceiveTime)
                    self.startMonoSec = nowMono
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
                switch result {
                case .failure(let err):
                    phase = .error
                    errorMessage = "Final NTP query failed: \(err)"
                    return
                case .success(let r):
                    let endMonoSec = currentMonotonicSeconds()
                    let endEpoch = r.serverTime + (endMonoSec - r.clientReceiveTime)

                    let monoElapsed = endMonoSec - startMonoSec
                    let trueElapsed = endEpoch - startEpoch

                    // ppm = (mono_elapsed / true_elapsed - 1) * 1e6
                    // If iPhone clock runs FAST (mono_elapsed > true_elapsed), ppm > 0.
                    let ppm = (monoElapsed / trueElapsed - 1.0) * 1e6

                    // Uncertainty: half-RTT each side, summed.
                    let unc = (startRTT + r.roundTripSeconds) * 0.5 / trueElapsed * 1e6

                    self.resultPPM = ppm
                    self.resultDetails = String(
                        format: """
                        iPhone elapsed: %.4f s
                        NTP    elapsed: %.4f s
                        difference:    %+.1f ms
                        RTT start/end: %.0f / %.0f ms
                        uncertainty:   ±%.1f ppm
                        """,
                        monoElapsed, trueElapsed,
                        (monoElapsed - trueElapsed) * 1000,
                        startRTT * 1000, r.roundTripSeconds * 1000,
                        unc
                    )
                    phase = .done
                }
            }
        }
    }

    private func stopAndDismiss() {
        timer?.invalidate(); timer = nil
        dismiss()
    }
}

// MARK: - Helpers

/// Helper duplicating monotonicSeconds() from NTPClient.swift. Kept
/// here so `@State` fields can be read on the main thread without
/// crossing module boundaries.
fileprivate func currentMonotonicSeconds() -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let host = mach_continuous_time()
    let nanos = Double(host) * Double(info.numer) / Double(info.denom)
    return nanos / 1e9
}
