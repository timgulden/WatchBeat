import SwiftUI
import WatchBeatCore

struct ContentView: View {
    @StateObject private var coordinator = MeasurementCoordinator()

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width

            // Fixed positions measured from bottom of safe area
            let cancelY = h - 100
            let buttonCenterY = h - 145
            let barsBottom = h - 195
            let barsHeight: CGFloat = 240
            let barsTop = barsBottom - barsHeight
            let captionY = barsTop - 20
            let headlineY = captionY - 30

            ZStack {
                // Title — always at top
                Text("WatchBeat")
                    .font(.largeTitle.bold())
                    .position(x: w / 2, y: 50)

                switch coordinator.state {
                case .idle:
                    idleOverlay(w: w, h: h, headlineY: headlineY, captionY: captionY,
                                barsTop: barsTop, barsBottom: barsBottom, barsHeight: barsHeight,
                                buttonCenterY: buttonCenterY)

                case .monitoring:
                    monitoringOverlay(w: w, headlineY: headlineY, captionY: captionY,
                                      barsTop: barsTop, barsHeight: barsHeight,
                                      buttonCenterY: buttonCenterY, cancelY: cancelY)

                case .recording(let elapsed, let liveQuality):
                    recordingOverlay(w: w, h: h, headlineY: headlineY, captionY: captionY,
                                     barsTop: barsTop, barsHeight: barsHeight,
                                     buttonCenterY: buttonCenterY, cancelY: cancelY,
                                     elapsed: elapsed, liveQuality: liveQuality)

                case .analyzing:
                    ProgressView("Analyzing...").font(.title3)
                        .position(x: w / 2, y: h / 2)

                case .result(let data):
                    resultOverlay(data: data, w: w, h: h)

                case .error(let message):
                    errorOverlay(message: message, w: w, h: h, buttonCenterY: buttonCenterY)
                }
            }
        }
        .edgesIgnoringSafeArea(.bottom)
    }

    // MARK: - Shared logo

    private func logoImage(w: CGFloat, headlineY: CGFloat) -> some View {
        let imageCenter = (80 + headlineY) / 2
        let imageSize = max(10, min(headlineY - 100, w - 80))
        return Image("WatchBeatMark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: imageSize, height: imageSize)
            .opacity(0.85)
            .position(x: w / 2, y: imageCenter)
    }

    // MARK: - Idle

    private func idleOverlay(w: CGFloat, h: CGFloat, headlineY: CGFloat, captionY: CGFloat,
                              barsTop: CGFloat, barsBottom: CGFloat, barsHeight: CGFloat,
                              buttonCenterY: CGFloat) -> some View {
        ZStack {
            logoImage(w: w, headlineY: headlineY)

            Text("Position your watch against the mic")
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(width: w - 40)
                .position(x: w / 2, y: headlineY)

            Text("Press your iPhone mic against the watch caseback, then tap Listen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: w - 40)
                .position(x: w / 2, y: captionY)

            Button(action: { coordinator.startMonitoring() }) {
                Text("Listen")
                    .font(.title3.bold())
                    .frame(width: w - 40)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .position(x: w / 2, y: buttonCenterY)
        }
    }

    // MARK: - Monitoring

    private func monitoringOverlay(w: CGFloat, headlineY: CGFloat, captionY: CGFloat,
                                    barsTop: CGFloat, barsHeight: CGFloat,
                                    buttonCenterY: CGFloat, cancelY: CGFloat) -> some View {
        ZStack {
            logoImage(w: w, headlineY: headlineY)

            Text("Position your watch against the mic")
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(width: w - 40)
                .position(x: w / 2, y: headlineY)

            Text("Look for a peak at your watch's beat rate")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: w - 40)
                .position(x: w / 2, y: captionY)

            FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                .frame(width: w - 40, height: barsHeight)
                .position(x: w / 2, y: barsTop + barsHeight / 2)

            Button(action: { coordinator.startMeasurement() }) {
                Text("Measure")
                    .font(.title3.bold())
                    .frame(width: w - 40)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .position(x: w / 2, y: buttonCenterY)

            Button("Cancel") { coordinator.stopMonitoring() }
                .foregroundStyle(.red)
                .position(x: w / 2, y: cancelY)
        }
    }

    // MARK: - Recording

    private func recordingOverlay(w: CGFloat, h: CGFloat, headlineY: CGFloat, captionY: CGFloat,
                                   barsTop: CGFloat, barsHeight: CGFloat,
                                   buttonCenterY: CGFloat, cancelY: CGFloat,
                                   elapsed: Double, liveQuality: Int) -> some View {
        ZStack {
            logoImage(w: w, headlineY: headlineY)

            Text("Listening...")
                .font(.headline)
                .position(x: w / 2, y: headlineY)

            Text(liveCaption(elapsed: elapsed, quality: liveQuality))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: w - 40)
                .position(x: w / 2, y: captionY)

            // Bars in same position as monitoring
            FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                .frame(width: w - 40, height: barsHeight)
                .position(x: w / 2, y: barsTop + barsHeight / 2)

            // Quality + progress below bars, above where button was
            VStack(spacing: 6) {
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
                    .frame(width: w - 40)
            }
            .position(x: w / 2, y: buttonCenterY - 10)

            Button("Cancel") { coordinator.cancelMeasurement() }
                .foregroundStyle(.red)
                .position(x: w / 2, y: cancelY)
        }
    }

    // MARK: - Result (uses its own layout, fills the screen)

    private func resultOverlay(data: MeasurementCoordinator.MeasurementDisplayData, w: CGFloat, h: CGFloat) -> some View {
        VStack(spacing: 2) {
            // Rate and quality
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(data.rateBPH) bph")
                        .font(.subheadline.bold())
                    Text("\(formatOscHz(Double(data.rateBPH) / 3600.0 / 2.0)) Hz")
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

            // Dial
            RateDialView(rateError: data.rateError, beatErrorMs: data.beatErrorMs)
                .frame(height: 310)
                .padding(.top, -8)

            // Timegraph
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

            Spacer()

            Button(action: { coordinator.startMonitoring() }) {
                Text("Measure Again")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 20)
        }
        .padding(.top, 80) // clear the WatchBeat title
        .padding(.horizontal, 20)
    }

    // MARK: - Error

    private func errorOverlay(message: String, w: CGFloat, h: CGFloat, buttonCenterY: CGFloat) -> some View {
        ZStack {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: w - 40)
            }
            .position(x: w / 2, y: h * 0.4)

            Button(action: { coordinator.startMonitoring() }) {
                Text("Try Again")
                    .font(.title3.bold())
                    .frame(width: w - 40)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .position(x: w / 2, y: buttonCenterY)
        }
    }

    // MARK: - Helpers

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

/// Format oscillation Hz for display — shows decimal for non-integer values like 2.75.
private func formatOscHz(_ hz: Double) -> String {
    if hz == hz.rounded() { return "\(Int(hz))" }
    let oneDecimal = String(format: "%.1f", hz)
    if Double(oneDecimal) == hz { return oneDecimal }
    return String(format: "%.2f", hz)
}

// MARK: - Frequency Bars

struct FrequencyBarsView: View {
    let ratePowers: [StandardBeatRate: Float]
    let selectedRate: StandardBeatRate?

    private let rates = StandardBeatRate.allCases

    var body: some View {
        let maxPower = ratePowers.values.max() ?? 1.0

        GeometryReader { geo in
            let labelHeight: CGFloat = 16
            let barAreaHeight = max(10, geo.size.height - labelHeight - 4)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(rates, id: \.self) { rate in
                    let power = ratePowers[rate] ?? 0
                    let normalizedHeight = maxPower > 0 ? CGFloat(power / maxPower) : 0
                    let isStrongest = power == maxPower && maxPower > 0 && power > 0

                    VStack(spacing: 2) {
                        // Spacer pushes bar to bottom of bar area
                        Spacer(minLength: 0)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(isStrongest ? Color.green : Color.blue)
                            .frame(height: max(2, normalizedHeight * barAreaHeight))

                        // Label always at the bottom
                        Text("\(formatOscHz(rate.oscillationHz)) Hz")
                            .font(.system(size: 10, weight: isStrongest ? .bold : .regular))
                            .foregroundStyle(isStrongest ? .primary : .secondary)
                            .frame(height: labelHeight)
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
