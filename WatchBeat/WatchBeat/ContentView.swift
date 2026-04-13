import SwiftUI
import WatchBeatCore

struct ContentView: View {
    @StateObject private var coordinator = MeasurementCoordinator()

    var body: some View {
        NavigationStack {
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
        } // NavigationStack
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

            // Frequency monitor — shows power at each standard beat rate
            FrequencyBarsView(
                ratePowers: coordinator.ratePowers,
                selectedRate: coordinator.selectedRate
            )
            .frame(height: 120)

            Button(action: { coordinator.startMeasurement() }) {
                VStack(spacing: 4) {
                    Text("Measure (30s)")
                        .font(.title2.bold())
                    if let rate = coordinator.selectedRate {
                        Text("at \(rate.rawValue) bph")
                            .font(.caption)
                    }
                }
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
        NavigationLink {
            RateSelectionView(selectedRate: $coordinator.selectedRate)
        } label: {
            HStack {
                Text("Beat rate:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(coordinator.selectedRate.map { rateLabel($0) } ?? "Auto-detect")
                    .bold()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func rateLabel(_ rate: StandardBeatRate) -> String {
        let hz = rate.hz == floor(rate.hz) ? "\(Int(rate.hz))" : String(format: "%.1f", rate.hz)
        if rate.isQuartz {
            return "\(rate.rawValue) bph / \(hz) Hz (quartz)"
        }
        return "\(rate.rawValue) bph / \(hz) Hz"
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
                    let isSelected = selectedRate == rate
                    let isStrongest = power == maxPower && maxPower > 0

                    VStack(spacing: 2) {
                        // Bar
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(isSelected: isSelected, isStrongest: isStrongest))
                            .frame(height: max(2, normalizedHeight * (geo.size.height - 30)))

                        // Label
                        Text("\(Int(rate.hz))")
                            .font(.system(size: 10, weight: isSelected ? .bold : .regular))
                            .foregroundStyle(isSelected ? .primary : .secondary)
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

// MARK: - Rate Selection

struct RateSelectionView: View {
    @Binding var selectedRate: StandardBeatRate?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                selectedRate = nil
                dismiss()
            } label: {
                HStack {
                    Text("Auto-detect")
                    Spacer()
                    if selectedRate == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }

            Section("Mechanical") {
                ForEach(StandardBeatRate.allCases.filter { !$0.isQuartz }, id: \.self) { rate in
                    Button {
                        selectedRate = rate
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(rate.rawValue) bph")
                                    .font(.body)
                                Text("\(Int(rate.hz)) Hz")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedRate == rate {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }

            Section("Quartz") {
                ForEach(StandardBeatRate.allCases.filter { $0.isQuartz }, id: \.self) { rate in
                    Button {
                        selectedRate = rate
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(rate.rawValue) bph")
                                    .font(.body)
                                Text("\(Int(rate.hz)) Hz")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedRate == rate {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Beat Rate")
        .foregroundStyle(.primary)
    }
}

#Preview {
    ContentView()
}
