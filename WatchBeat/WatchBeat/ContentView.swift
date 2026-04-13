import SwiftUI
import WatchBeatCore

struct ContentView: View {
    @StateObject private var coordinator = MeasurementCoordinator()

    var body: some View {
        VStack(spacing: 24) {
            Text("WatchBeat")
                .font(.largeTitle.bold())

            Spacer()

            switch coordinator.state {
            case .idle:
                idleView
            case .monitoring:
                monitoringView
            case .requestingPermission:
                ProgressView("Requesting microphone access...")
            case .recording(let elapsed, let total):
                recordingView(elapsed: elapsed, total: total)
            case .analyzing:
                ProgressView("Analyzing...")
                    .font(.title3)
            case .result(let data):
                resultView(data: data)
            case .error(let message):
                errorView(message: message)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 16) {
            Text("Press your iPhone mic against the watch caseback, then tap Listen to check signal level.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button(action: { coordinator.startMonitoring() }) {
                Text("Listen")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Live level monitor

    private var monitoringView: some View {
        VStack(spacing: 20) {
            Text("Position your watch against the mic")
                .font(.headline)

            // Rate selector
            ratePicker

            // Level meter
            VStack(spacing: 8) {
                LevelMeterView(level: coordinator.audioLevel)
                    .frame(height: 40)

                Text(levelDescription(coordinator.audioLevel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: { coordinator.startMeasurement() }) {
                Text("Measure (30s)")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Cancel") {
                coordinator.stopMonitoring()
            }
            .foregroundStyle(.red)
        }
    }

    // MARK: - Rate picker

    private var ratePicker: some View {
        HStack {
            Text("Beat rate:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Beat rate", selection: $coordinator.selectedRate) {
                Text("Auto-detect").tag(nil as StandardBeatRate?)
                ForEach(StandardBeatRate.allCases, id: \.self) { rate in
                    Text(rateLabel(rate)).tag(rate as StandardBeatRate?)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func rateLabel(_ rate: StandardBeatRate) -> String {
        let hz = rate.hz == floor(rate.hz) ? "\(Int(rate.hz))" : String(format: "%.1f", rate.hz)
        if rate.isQuartz {
            return "\(rate.rawValue) bph / \(hz) Hz (quartz)"
        }
        return "\(rate.rawValue) bph / \(hz) Hz"
    }

    private func levelDescription(_ level: Float) -> String {
        if level < 0.001 {
            return "No signal detected"
        } else if level < 0.01 {
            return "Very weak signal"
        } else if level < 0.05 {
            return "Weak signal -- try pressing harder"
        } else if level < 0.2 {
            return "Good signal"
        } else {
            return "Strong signal"
        }
    }

    // MARK: - Recording

    private func recordingView(elapsed: Double, total: Double) -> some View {
        VStack(spacing: 16) {
            Text("Recording...")
                .font(.title3)

            ProgressView(value: elapsed, total: total)
                .progressViewStyle(.linear)

            Text("\(Int(elapsed))s / \(Int(total))s")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("Cancel") {
                coordinator.cancelMeasurement()
            }
            .foregroundStyle(.red)
        }
    }

    // MARK: - Result

    private func resultView(data: MeasurementCoordinator.MeasurementDisplayData) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("Detected Rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(data.rateBPH) bph")
                    .font(.title2.bold())
            }

            VStack(spacing: 4) {
                Text("Rate Error")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(data.rateErrorSecondsPerDay)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }

            if let beatError = data.beatErrorMilliseconds {
                VStack(spacing: 4) {
                    Text("Beat Error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(beatError)
                        .font(.title3.monospacedDigit())
                }
            }

            HStack(spacing: 32) {
                VStack(spacing: 4) {
                    Text("Quality")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(data.qualityPercent)%")
                        .font(.body.monospacedDigit())
                }
                VStack(spacing: 4) {
                    Text("Ticks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(data.tickCount)")
                        .font(.body.monospacedDigit())
                }
            }

            DisclosureGroup("Diagnostics") {
                Text(data.diagnosticText)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)

            Button(action: { coordinator.startMonitoring() }) {
                Text("Measure Again")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Try Again") {
                coordinator.startMonitoring()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Level Meter

struct LevelMeterView: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray5))

                // Level bar (log-scaled for better visibility of quiet signals)
                let logLevel = level > 0 ? max(0, 1.0 + log10(max(Double(level), 1e-4)) / 4.0) : 0
                let barWidth = min(CGFloat(logLevel), 1.0) * geo.size.width
                RoundedRectangle(cornerRadius: 6)
                    .fill(barColor)
                    .frame(width: max(0, barWidth))
            }
        }
    }

    private var barColor: Color {
        if level < 0.01 {
            return .red
        } else if level < 0.05 {
            return .orange
        } else {
            return .green
        }
    }
}

#Preview {
    ContentView()
}
