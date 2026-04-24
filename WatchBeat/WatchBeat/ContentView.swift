import SwiftUI
import WatchBeatCore

struct ContentView: View {
    @StateObject private var coordinator = MeasurementCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch coordinator.state {
            case .idle:
                IdleScreen(coordinator: coordinator)
            case .monitoring:
                MonitoringScreen(coordinator: coordinator)
            case .recording:
                RecordingScreen(coordinator: coordinator)
            case .analyzing:
                AnalyzingScreen()
            case .result(let data):
                ResultScreen(data: data, coordinator: coordinator)
            case .needsService(let data):
                NeedsServiceScreen(data: data, coordinator: coordinator)
            case .error:
                ErrorScreen(coordinator: coordinator)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                coordinator.handleBackgrounded()
            }
        }
    }
}

// MARK: - Shared Layout

/// Consistent screen layout used by idle, monitoring, recording, and error screens.
/// Anchors the button area at a fixed distance from the bottom so buttons don't
/// shift between screens. The logo area flexes to fill remaining space.
struct ScreenLayout<Logo: View, TextContent: View, Bars: View, Controls: View>: View {
    @ViewBuilder var logo: Logo
    @ViewBuilder var textContent: TextContent
    @ViewBuilder var bars: Bars
    @ViewBuilder var controls: Controls

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            // Logo — fills available space
            logo
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Text area — top-aligned with minimum height so the headline stays
            // in the same position regardless of caption length. 80pt covers
            // 2 lines at subheadline size on all iPhone widths.
            textContent
                .padding(.horizontal, 20)
                .frame(minHeight: 80, alignment: .top)
                .padding(.bottom, 12)

            // Frequency bars
            bars
                .padding(.horizontal, 20)

            // Bottom controls — fixed height region
            controls
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(height: 110)
        }
    }
}

// MARK: - Logo Helpers

/// Watch logo with optional GMT hand overlay. Always renders the same view
/// hierarchy (wheel + hand + marker) so layout is identical regardless of
/// whether the hand is visible. Hand and marker are hidden via opacity.
struct WatchLogo: View {
    var showHand: Bool = false
    var angle: Double = 0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2

            ZStack {
                // Wheel + hand always in same ZStack — rotate together
                ZStack {
                    Image("WatchBeatMark")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .opacity(0.85)

                    GMTHandView(radius: radius * 0.85)
                        .rotationEffect(.degrees(-30))
                        .opacity(showHand ? 1 : 0)
                }
                .rotationEffect(.degrees(angle))

                // 12:00 marker stays fixed
                GMTMarkerView()
                    .frame(width: 12, height: 12)
                    .offset(y: -radius - 2)
                    .opacity(showHand ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 280, maxHeight: 280)
        .padding(30)
        .accessibilityHidden(true)
    }
}

// MARK: - Action Button Style

/// Consistent action button used across all screens.
struct ActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
    }
}

// MARK: - Idle Screen

struct IdleScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        ScreenLayout {
            WatchLogo()
        } textContent: {
            Text("Place mic against watch caseback")
                .font(.headline)
                .multilineTextAlignment(.center)
        } bars: {
            VStack(alignment: .leading, spacing: 12) {
                tipRow(icon: "ear", text: "Move to a quiet room away from fans, appliances, and conversation.")
                tipRow(icon: "arrow.down.to.line", text: "Place the watch face-down on a hard surface. Use a soft cloth to protect the crystal.")
                tipRow(icon: "iphone.gen3", text: "Press the bottom edge of your iPhone firmly against the caseback.")
                tipRow(icon: "chart.bar.fill", text: "Adjust position to maximize the frequency bar at your watch's beat rate.")
                tipRow(icon: "iphone.slash", text: "If using a thick phone case, try removing it for better acoustic contact.")
            }
            .padding(.horizontal, 4)
            .offset(y: -20)
            .frame(height: 240)
        } controls: {
            VStack(spacing: 10) {
                ActionButton(title: "Listen") {
                    coordinator.startMonitoring()
                }
            }
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Monitoring Screen

struct MonitoringScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        TimelineView(.animation) { _ in
            ScreenLayout {
                WatchLogo(showHand: true, angle: wheelAngle())
            } textContent: {
                VStack(spacing: 6) {
                    Text("Place mic against watch caseback")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Look for a peak at your watch's beat rate")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } bars: {
                FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                    .frame(height: 240)
            } controls: {
                VStack(spacing: 10) {
                    ActionButton(title: "Measure") {
                        coordinator.startMeasurement()
                    }
                    Button("Cancel") { coordinator.stopMonitoring() }
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func wheelAngle() -> Double {
        // After the first monitoring session, always start at 12:00
        guard coordinator.needsSweep else { return 30 }
        guard let start = coordinator.monitoringStartTime else { return 0 }
        let hasData = coordinator.ratePowers.values.contains { $0 > 0 }
        // Once data arrives, lock to 12:00 — sweep is done
        if hasData { return 30 }
        // Cold start: 1-second pause, then 5-second sweep from 11:00 to 12:00
        let elapsed = (ContinuousClock.now - start).asSeconds
        let sweepElapsed = max(0, elapsed - 1.0)
        let progress = min(sweepElapsed / 5.0, 1.0)
        return progress * 30
    }
}

// MARK: - Recording Screen

struct RecordingScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = elapsedTime()
            let current = coordinator.currentQuality
            let best = coordinator.bestQualitySoFar

            ScreenLayout {
                WatchLogo(showHand: true, angle: 30 + (elapsed / coordinator.maxRecordingTime) * 360)
            } textContent: {
                VStack(spacing: 6) {
                    Text("Listening...")
                        .font(.headline)
                    Text(liveCaption(elapsed: elapsed, quality: best))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } bars: {
                FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                    .frame(height: 240)
            } controls: {
                VStack(spacing: 10) {
                    VStack(spacing: 4) {
                        // Current quality — small
                        HStack(spacing: 4) {
                            Text("Current:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(current)%")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(MeasurementConstants.qualityColor(current))
                        }
                        // Progress bar — tracks best
                        ProgressView(value: min(Double(best), 80), total: 80)
                            .progressViewStyle(.linear)
                            .tint(MeasurementConstants.qualityColor(best))
                        // Best quality — prominent
                        HStack(spacing: 4) {
                            Text("Best:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(best)%")
                                .font(.title2.bold().monospacedDigit())
                                .foregroundStyle(MeasurementConstants.qualityColor(best))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Measurement quality")
                    .accessibilityValue("Current \(current) percent, best \(best) percent")
                    Button("Cancel") { coordinator.cancelMeasurement() }
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func elapsedTime() -> Double {
        guard let start = coordinator.recordingStartTime else { return 0 }
        return min((ContinuousClock.now - start).asSeconds, coordinator.maxRecordingTime)
    }

    private func liveCaption(elapsed: Double, quality: Int) -> String {
        if elapsed < 15 { return "Collecting..." }
        if quality >= 80 { return "Great signal! Finishing..." }
        if quality > 0 { return "Searching for good contact..." }
        return "Waiting for first analysis..."
    }

}

// MARK: - Analyzing Screen

struct AnalyzingScreen: View {
    var body: some View {
        VStack {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)
            Spacer()
            ProgressView("Analyzing...")
                .font(.title3)
            Spacer()
        }
    }
}

// MARK: - Result Screen

struct ResultScreen: View {
    let data: MeasurementCoordinator.MeasurementDisplayData
    @ObservedObject var coordinator: MeasurementCoordinator
    @State private var liftAngleText: String = ""
    @FocusState private var liftAngleFocused: Bool

    /// Compute amplitude on the fly from stored pulse widths + current lift angle.
    private var amplitudeDegrees: Double? {
        guard let pw = data.pulseWidths else { return nil }
        return AmplitudeEstimator.combinedAmplitude(
            pulseWidths: pw,
            beatRate: StandardBeatRate.nearest(toHz: Double(data.rateBPH) / 3600.0),
            rateErrorSecondsPerDay: data.rateError,
            liftAngleDegrees: coordinator.liftAngleDegrees
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)
                .padding(.bottom, 4)

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
                    .frame(maxHeight: 310)
                    .padding(.top, -8)

                // Disorderly warning
                if data.isDisorderly {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Tick/tock pattern is disorderly — rate and beat error may be unreliable. Check the timegraph below.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.red, lineWidth: 1)
                    )
                    .cornerRadius(6)
                    .padding(.top, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Warning: tick and tock pattern is disorderly. Rate and beat error may be unreliable. Check the timegraph.")
                }

                // Lift Angle / Amplitude row
                if data.pulseWidths != nil {
                    HStack(alignment: .top) {
                        // Lift Angle input (left)
                        VStack(spacing: 2) {
                            Text("Lift Angle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 2) {
                                TextField("", text: $liftAngleText)
                                    .keyboardType(.decimalPad)
                                    .font(.system(.body, design: .rounded, weight: .bold))
                                    .multilineTextAlignment(.center)
                                    .frame(width: 56, height: 36)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(6)
                                    .focused($liftAngleFocused)
                                    .onChange(of: liftAngleText) { _, newValue in
                                        if let val = Double(newValue), val > 0 && val <= 90 {
                                            coordinator.liftAngleDegrees = val
                                        }
                                    }
                                Text("°")
                                    .font(.body.bold())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        // Amplitude display (right)
                        VStack(spacing: 2) {
                            Text("Amplitude")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let amp = amplitudeDegrees {
                                Text("\(Int(amp))°")
                                    .font(.system(.title3, design: .rounded, weight: .bold))
                            } else {
                                Text("---")
                                    .font(.system(.title3, design: .rounded, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.top, -4)
                }

                // Timegraph — centered between dial and button
                Spacer(minLength: 8)

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
                    .aspectRatio(1.618, contentMode: .fit)
                }

                Spacer(minLength: 8)

                ActionButton(title: "Measure Again") {
                    coordinator.startMonitoring()
                }
                .padding(.bottom, 20)
            }
            .padding(.horizontal, 20)
        }
        .ignoresSafeArea(.keyboard)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { liftAngleFocused = false }
            }
        }
        .onAppear {
            liftAngleText = String(format: "%.0f", coordinator.liftAngleDegrees)
        }
    }
}

// MARK: - Error Screen

struct ErrorScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Signal too weak")
                        .font(.title3.bold())
                }
                .frame(maxWidth: .infinity, alignment: .center)

                Text("Tips for a better reading:")
                    .font(.subheadline.bold())
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 12) {
                    tipRow(icon: "ear", text: "Move to a quiet room away from fans, appliances, and conversation.")
                    tipRow(icon: "arrow.down.to.line", text: "Place the watch face-down on a hard surface. Use a soft cloth to protect the crystal.")
                    tipRow(icon: "iphone.gen3", text: "Press the bottom edge of your iPhone firmly against the caseback.")
                    tipRow(icon: "chart.bar.fill", text: "Adjust position to maximize the frequency bar at your watch's beat rate.")
                    tipRow(icon: "iphone.slash", text: "If using a thick phone case, try removing it for better acoustic contact.")
                }

                Text("Some watches are very quiet and may require several attempts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)

            Spacer()

            ActionButton(title: "Try Again") {
                coordinator.startMonitoring()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Needs Service Screen

struct NeedsServiceScreen: View {
    let data: MeasurementCoordinator.NeedsServiceData
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Watch needs service")
                        .font(.title3.bold())
                }
                .frame(maxWidth: .infinity, alignment: .center)

                VStack(spacing: 4) {
                    Text(rateErrorDisplay)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(severityColor)
                        .monospacedDigit()
                    Text("per day \(data.rateErrorSecondsPerDay >= 0 ? "fast" : "slow")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)

                HStack(spacing: 8) {
                    Text("Severity:")
                        .font(.subheadline.bold())
                    Text(severityLabel)
                        .font(.subheadline.bold())
                        .foregroundStyle(severityColor)
                }

                Text("The rate was identified with high confidence at \(data.rateBPH) bph, but the movement is running far outside the normal ±120 s/day range for a healthy mechanical watch. A cleaning, lubrication, or regulation is likely needed.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("For reference, a well-regulated modern mechanical watch runs within ±10 s/day; a typical vintage movement within ±60 s/day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)

            Spacer()

            ActionButton(title: "Try Again") {
                coordinator.startMonitoring()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watch needs service. Running \(Int(abs(data.rateErrorSecondsPerDay))) seconds per day \(data.rateErrorSecondsPerDay >= 0 ? "fast" : "slow") at \(data.rateBPH) beats per hour. Severity: \(severityLabel).")
    }

    private var rateErrorDisplay: String {
        let secs = Int(data.rateErrorSecondsPerDay.rounded())
        let sign = secs >= 0 ? "+" : ""
        return "\(sign)\(secs) s"
    }

    private var severityLabel: String {
        let abs = Swift.abs(data.rateErrorSecondsPerDay)
        if abs >= 5000 { return "Severe" }
        if abs >= 1000 { return "Significant" }
        return "Elevated"
    }

    private var severityColor: Color {
        let abs = Swift.abs(data.rateErrorSecondsPerDay)
        if abs >= 5000 { return .red }
        if abs >= 1000 { return .orange }
        return .yellow
    }
}

#Preview {
    ContentView()
}
