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
            case .recording(let elapsed, let liveQuality):
                recordingView(elapsed: elapsed, liveQuality: liveQuality)
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

            Text("Look for a peak at your watch's beat rate")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Frequency monitor — shows power at each standard beat rate
            FrequencyBarsView(
                ratePowers: coordinator.ratePowers,
                selectedRate: nil
            )
            .frame(height: 120)

            Button(action: { coordinator.startMeasurement() }) {
                Text("Measure")
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


    // MARK: - Recording

    private func recordingView(elapsed: Double, liveQuality: Int) -> some View {
        VStack(spacing: 16) {
            Text("Listening...")
                .font(.title3)

            FrequencyBarsView(
                ratePowers: coordinator.ratePowers,
                selectedRate: nil
            )
            .frame(height: 100)

            // Live quality indicator
            VStack(spacing: 4) {
                HStack {
                    Text("Quality:")
                        .foregroundStyle(.secondary)
                    Text("\(liveQuality)%")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(liveQuality >= 50 ? .green : liveQuality > 0 ? .orange : .secondary)
                }

                if elapsed < 15 {
                    Text("Collecting... \(Int(elapsed))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if liveQuality >= 50 {
                    Text("Good signal! Finishing...")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if liveQuality > 0 {
                    Text("Searching for good contact... \(Int(elapsed))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Waiting for first analysis... \(Int(elapsed))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: min(Double(liveQuality), 50), total: 50)
                .progressViewStyle(.linear)
                .tint(liveQuality >= 50 ? .green : .orange)

            Button("Cancel") {
                coordinator.cancelMeasurement()
            }
            .foregroundStyle(.red)
        }
    }

    // MARK: - Result

    private func resultView(data: MeasurementCoordinator.MeasurementDisplayData) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                // Rate + quality on one line
                HStack {
                    Text("\(data.rateBPH) bph")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    QualityBadgeView(percent: data.qualityPercent)
                }

                // Rate error dial with beat error in the gap
                RateDialView(rateError: data.rateError, beatErrorMs: data.beatErrorMs)
                    .frame(height: 200)

                // Timegrapher plot
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Timegrapher")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(.blue).frame(width: 5, height: 5)
                            Text("tick").font(.caption2).foregroundStyle(.secondary)
                            Circle().fill(.cyan).frame(width: 5, height: 5)
                            Text("tock").font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    TimegrapherPlotView(
                        residuals: data.tickResiduals,
                        rateErrorPerDay: data.rateError
                    )
                    .frame(height: 130)
                }

                // Diagnostics
                DisclosureGroup("Diagnostics") {
                    Text(data.diagnosticText)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)

                Button(action: { coordinator.startMonitoring() }) {
                    Text("Measure Again")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
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

// MARK: - Frequency Bars

struct FrequencyBarsView: View {
    let ratePowers: [StandardBeatRate: Float]
    let selectedRate: StandardBeatRate?

    private let rates = StandardBeatRate.allCases

    var body: some View {
        let maxPower = ratePowers.values.max() ?? 1.0

        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(rates, id: \.self) { rate in
                    let power = ratePowers[rate] ?? 0
                    let normalizedHeight = maxPower > 0 ? CGFloat(power / maxPower) : 0
                    let isSelected = selectedRate == rate || selectedRate == nil
                    let isStrongest = power == maxPower && maxPower > 0 && power > 0

                    VStack(spacing: 2) {
                        // Bar
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(isSelected: isSelected, isStrongest: isStrongest))
                            .frame(height: max(2, normalizedHeight * (geo.size.height - 30)))

                        // Label
                        Text("\(Int(rate.hz)) Hz")
                            .font(.system(size: 9, weight: isStrongest ? .bold : .regular))
                            .foregroundStyle(isStrongest ? .primary : .secondary)
                    }
                }
            }
        }
    }

    private func barColor(isSelected: Bool, isStrongest: Bool) -> Color {
        if isSelected && isStrongest {
            return .green
        } else if isSelected {
            return .blue
        } else if isStrongest {
            return .orange
        }
        return Color(.systemGray4)
    }
}


#Preview {
    ContentView()
}
