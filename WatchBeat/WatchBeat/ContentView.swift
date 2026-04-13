import SwiftUI

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
            Text("Press your iPhone firmly against the watch, then tap Measure.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button(action: { coordinator.startMeasurement() }) {
                Text("Measure")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
            // Rate
            VStack(spacing: 4) {
                Text("Detected Rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(data.rateBPH) bph")
                    .font(.title2.bold())
            }

            // Rate error — the main number
            VStack(spacing: 4) {
                Text("Rate Error")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(data.rateErrorSecondsPerDay)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
            }

            // Beat error (mechanical only)
            if let beatError = data.beatErrorMilliseconds {
                VStack(spacing: 4) {
                    Text("Beat Error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(beatError)
                        .font(.title3.monospacedDigit())
                }
            }

            // Quality + tick count
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

            // Diagnostics (collapsible)
            DisclosureGroup("Diagnostics") {
                Text(data.diagnosticText)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)

            Button(action: { coordinator.startMeasurement() }) {
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
                coordinator.startMeasurement()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ContentView()
}
