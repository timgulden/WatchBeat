import SwiftUI
import WatchBeatCore

struct ContentView: View {
    @StateObject private var coordinator = MeasurementCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.bottom, 8)

            // Main content area — fills available space
            Group {
                switch coordinator.state {
                case .idle:
                    idleContent
                case .monitoring:
                    monitoringContent
                case .recording(let elapsed, let liveQuality):
                    recordingContent(elapsed: elapsed, liveQuality: liveQuality)
                case .analyzing:
                    Spacer()
                    ProgressView("Analyzing...")
                        .font(.title3)
                    Spacer()
                case .result(let data):
                    resultView(data: data)
                case .error(let message):
                    errorView(message: message)
                }
            }
            .frame(maxHeight: .infinity)

            // Action button — fixed position at bottom for idle/monitoring/recording
            switch coordinator.state {
            case .idle:
                actionButton("Listen") { coordinator.startMonitoring() }
            case .monitoring:
                actionButton("Measure") { coordinator.startMeasurement() }
                Button("Cancel") { coordinator.stopMonitoring() }
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            case .recording:
                Button("Cancel") { coordinator.cancelMeasurement() }
                    .foregroundStyle(.red)
            case .result:
                actionButton("Measure Again") { coordinator.startMonitoring() }
            default:
                EmptyView()
            }
        }
        .padding()
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: - Idle content (between title and button)

    private var idleContent: some View {
        VStack(spacing: 12) {
            Image("WatchBeatMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.85)
                .padding(.horizontal, 40)

            Spacer()

            Text("Position your watch against the mic")
                .font(.headline)

            Text("Press your iPhone mic against the watch caseback, then tap Listen.")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Monitoring content

    private var monitoringContent: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Position your watch against the mic")
                .font(.headline)

            Text("Look for a peak at your watch's beat rate")
                .font(.caption)
                .foregroundStyle(.secondary)

            FrequencyBarsView(
                ratePowers: coordinator.ratePowers,
                selectedRate: nil
            )
            .frame(height: 120)
        }
    }

    // MARK: - Recording content

    private func recordingContent(elapsed: Double, liveQuality: Int) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Listening...")
                .font(.title3)

            FrequencyBarsView(
                ratePowers: coordinator.ratePowers,
                selectedRate: nil
            )
            .frame(height: 100)

            VStack(spacing: 4) {
                HStack {
                    Text("Quality:")
                        .foregroundStyle(.secondary)
                    Text("\(liveQuality)%")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(liveQuality >= 80 ? .green : liveQuality >= 50 ? .green : liveQuality >= 30 ? .orange : liveQuality > 0 ? .red : .secondary)
                }

                if elapsed < 15 {
                    Text("Collecting... \(Int(elapsed))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if liveQuality >= 80 {
                    Text("Great signal! Finishing...")
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

            ProgressView(value: min(Double(liveQuality), 80), total: 80)
                .progressViewStyle(.linear)
                .tint(liveQuality >= 80 ? .green : liveQuality >= 50 ? .green.opacity(0.7) : .orange)
        }
    }

    // MARK: - Result

    private func resultView(data: MeasurementCoordinator.MeasurementDisplayData) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(data.rateBPH) bph")
                        .font(.subheadline.bold())
                    Text("\(Int(Double(data.rateBPH) / 3600.0)) Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    QualityBadgeView(percent: data.qualityPercent)
                    Text("Measurement Quality")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, -8)

            RateDialView(rateError: data.rateError, beatErrorMs: data.beatErrorMs)
                .frame(height: 330)
                .padding(.top, -12)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Timegraph")
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

                TimegraphView(
                    residuals: data.tickResiduals,
                    rateErrorPerDay: data.rateError,
                    beatRateHz: Double(data.rateBPH) / 3600.0
                )
                .frame(height: 120)
            }
            .padding(.top, -8)
        }
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

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
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(isSelected: isSelected, isStrongest: isStrongest))
                            .frame(height: max(2, normalizedHeight * (geo.size.height - 30)))

                        Text("\(Int(rate.hz)) Hz")
                            .font(.system(size: 9, weight: isStrongest ? .bold : .regular))
                            .foregroundStyle(isStrongest ? .primary : .secondary)
                    }
                }
            }
        }
    }

    private func barColor(isSelected: Bool, isStrongest: Bool) -> Color {
        if isSelected && isStrongest { return .green }
        else if isSelected { return .blue }
        else if isStrongest { return .orange }
        return Color(.systemGray4)
    }
}

#Preview {
    ContentView()
}
