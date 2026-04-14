import SwiftUI
import WatchBeatCore

struct ContentView: View {
    @StateObject private var coordinator = MeasurementCoordinator()

    var body: some View {
        GeometryReader { geo in
            let screenH = geo.size.height
            // The headline text sits at 45% from the top
            let headlineY = screenH * 0.45

            VStack(spacing: 0) {
                Text("WatchBeat")
                    .font(.largeTitle.bold())
                    .padding(.top, 8)

                switch coordinator.state {
                case .idle:
                    idleView(headlineY: headlineY)
                case .monitoring:
                    monitoringView(headlineY: headlineY)
                case .recording(let elapsed, let liveQuality):
                    recordingView(elapsed: elapsed, liveQuality: liveQuality, headlineY: headlineY)
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
            .padding(.horizontal)
        }
    }

    // MARK: - Idle

    private func idleView(headlineY: CGFloat) -> some View {
        VStack(spacing: 12) {
            // Image centered between title and headline position
            // Title is ~50pt from top. Headline is at headlineY.
            // Image fills the gap.
            Image("WatchBeatMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.85)
                .padding(.horizontal, 20)
                .frame(height: headlineY - 100) // title ~50pt + spacing

            Text("Position your watch against the mic")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Press your iPhone mic against the watch caseback, then tap Listen.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            primaryButton("Listen") { coordinator.startMonitoring() }
                .padding(.top, 4)

            Spacer()
        }
    }

    // MARK: - Monitoring

    private func monitoringView(headlineY: CGFloat) -> some View {
        VStack(spacing: 12) {
            Spacer()
                .frame(height: headlineY - 100)

            Text("Position your watch against the mic")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Look for a peak at your watch's beat rate")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                .frame(height: 120)

            primaryButton("Measure") { coordinator.startMeasurement() }
                .padding(.top, 4)

            Button("Cancel") { coordinator.stopMonitoring() }
                .foregroundStyle(.red)
                .padding(.top, 2)

            Spacer()
        }
    }

    // MARK: - Recording

    private func recordingView(elapsed: Double, liveQuality: Int, headlineY: CGFloat) -> some View {
        VStack(spacing: 10) {
            Spacer()
                .frame(height: headlineY - 100)

            Text("Listening...")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(liveCaption(elapsed: elapsed, quality: liveQuality))
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            Button("Cancel") { coordinator.cancelMeasurement() }
                .foregroundStyle(.red)
                .padding(.top, 4)

            Spacer()
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

            RateDialView(rateError: data.rateError, beatErrorMs: data.beatErrorMs)
                .frame(maxHeight: .infinity)
                .padding(.vertical, -4)

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

            primaryButton("Measure Again") { coordinator.startMonitoring() }
                .padding(.top, 6)
        }
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text(message)
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            primaryButton("Try Again") { coordinator.startMonitoring() }
        }
    }

    // MARK: - Helpers

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
    }

    private func liveCaption(elapsed: Double, quality: Int) -> String {
        if elapsed < 15 { return "Collecting... \(Int(elapsed))s" }
        if quality >= 80 { return "Great signal! Finishing..." }
        if quality > 0 { return "Searching for good contact... \(Int(elapsed))s" }
        return "Waiting for first analysis... \(Int(elapsed))s"
    }

    private func qualityColor(_ q: Int) -> Color {
        if q >= 50 { return .green }
        if q >= 30 { return .orange }
        if q > 0 { return .red }
        return .secondary
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
                    let isStrongest = power == maxPower && maxPower > 0 && power > 0

                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isStrongest ? Color.green : Color.blue)
                            .frame(height: max(2, normalizedHeight * (geo.size.height - 30)))

                        Text("\(Int(rate.hz)) Hz")
                            .font(.system(size: 9, weight: isStrongest ? .bold : .regular))
                            .foregroundStyle(isStrongest ? .primary : .secondary)
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
