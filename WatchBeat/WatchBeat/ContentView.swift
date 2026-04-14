import SwiftUI
import WatchBeatCore

struct ContentView: View {
    @StateObject private var coordinator = MeasurementCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.bottom, 4)

            switch coordinator.state {
            case .idle:
                idleView
            case .monitoring:
                monitoringView
            case .recording(let elapsed, let liveQuality):
                recordingView(elapsed: elapsed, liveQuality: liveQuality)
            case .analyzing:
                Spacer()
                ProgressView("Analyzing...").font(.title3)
                Spacer()
            case .result(let data):
                resultView(data: data)
            case .error(let message):
                errorView(message: message)
            }
        }
        .padding()
    }

    // MARK: - Shared bottom section (button aligns across screens)

    /// The bottom section shared by idle, monitoring, and recording screens.
    /// Everything from the headline down is identical in position.
    private func bottomSection(
        headline: String,
        caption: String,
        middleContent: AnyView,
        buttonTitle: String,
        buttonAction: @escaping () -> Void,
        showCancel: Bool = false,
        cancelAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 16) {
            Text(headline)
                .font(.headline)

            Text(caption)
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.secondary)

            middleContent

            Button(action: buttonAction) {
                Text(buttonTitle)
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if showCancel, let cancelAction {
                Button("Cancel", action: cancelAction)
                    .foregroundStyle(.red)
            } else {
                // Invisible placeholder to keep button position consistent
                Text(" ").font(.body).opacity(0)
            }
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 0) {
            // Balance wheel fills the space between title and bottom section
            Image("WatchBeatMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.85)
                .padding(.horizontal, 30)
                .frame(maxHeight: .infinity)

            bottomSection(
                headline: "Position your watch against the mic",
                caption: "Press your iPhone mic against the watch caseback, then tap Listen.",
                middleContent: AnyView(Color.clear.frame(height: 120)),
                buttonTitle: "Listen",
                buttonAction: { coordinator.startMonitoring() }
            )
        }
    }

    // MARK: - Monitoring

    private var monitoringView: some View {
        VStack(spacing: 0) {
            Spacer()

            bottomSection(
                headline: "Position your watch against the mic",
                caption: "Look for a peak at your watch's beat rate",
                middleContent: AnyView(
                    FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                        .frame(height: 120)
                ),
                buttonTitle: "Measure",
                buttonAction: { coordinator.startMeasurement() },
                showCancel: true,
                cancelAction: { coordinator.stopMonitoring() }
            )
        }
    }

    // MARK: - Recording

    private func recordingView(elapsed: Double, liveQuality: Int) -> some View {
        VStack(spacing: 0) {
            Spacer()

            bottomSection(
                headline: "Listening...",
                caption: liveQualityCaption(elapsed: elapsed, quality: liveQuality),
                middleContent: AnyView(
                    VStack(spacing: 8) {
                        FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                            .frame(height: 80)

                        HStack {
                            Text("Quality:")
                                .foregroundStyle(.secondary)
                            Text("\(liveQuality)%")
                                .font(.title2.bold().monospacedDigit())
                                .foregroundStyle(qualityColor(liveQuality))
                        }

                        ProgressView(value: min(Double(liveQuality), 80), total: 80)
                            .progressViewStyle(.linear)
                            .tint(liveQuality >= 80 ? .green : liveQuality >= 50 ? .green.opacity(0.7) : .orange)
                    }
                ),
                buttonTitle: "Cancel",
                buttonAction: { coordinator.cancelMeasurement() }
            )
        }
    }

    private func liveQualityCaption(elapsed: Double, quality: Int) -> String {
        if elapsed < 15 { return "Collecting... \(Int(elapsed))s" }
        if quality >= 80 { return "Great signal! Finishing..." }
        if quality > 0 { return "Searching for good contact... \(Int(elapsed))s" }
        return "Waiting for first analysis... \(Int(elapsed))s"
    }

    private func qualityColor(_ q: Int) -> Color {
        if q >= 80 { return .green }
        if q >= 50 { return .green }
        if q >= 30 { return .orange }
        if q > 0 { return .red }
        return .secondary
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

            RateDialView(rateError: data.rateError, beatErrorMs: data.beatErrorMs)
                .frame(height: 300)
                .padding(.top, -8)

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
                .frame(height: 110)
            }
            .padding(.top, -4)

            Spacer(minLength: 8)

            Button(action: { coordinator.startMonitoring() }) {
                Text("Measure Again")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text(" ").font(.body).opacity(0)
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

            Text(" ").font(.body).opacity(0)
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
