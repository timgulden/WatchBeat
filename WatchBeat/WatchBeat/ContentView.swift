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
            case .error(let message):
                ErrorScreen(message: message, coordinator: coordinator)
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

/// Two-square layout used by idle, listening, and measuring screens.
///
/// The bottom content is a near-screen-width square (graph + caption); the
/// top content is a smaller square (wheel + 12-o'clock marker) that centers
/// in the remaining space above it. Both squares counter-rotate together by
/// `rotation` so the content reads upright regardless of phone pose —
/// squares are chosen so their bounding boxes are invariant under 90°
/// rotation. The title and bottom controls never rotate.
struct SquareScreenLayout<SmallContent: View, BigContent: View, Controls: View>: View {
    var rotation: Double = 0
    @ViewBuilder var smallSquare: SmallContent
    @ViewBuilder var bigSquare: BigContent
    @ViewBuilder var controls: Controls

    var body: some View {
        GeometryReader { outer in
            let bigSide = min(outer.size.width - 16, 400)
            VStack(spacing: 0) {
                Text("WatchBeat")
                    .font(.largeTitle.bold())
                    .padding(.top, 12)

                // Small square area — fills remaining vertical space between
                // title and big square, with the square content centered.
                smallSquare
                    .rotationEffect(.degrees(rotation))
                    .animation(.easeInOut(duration: 0.28), value: rotation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Big square — fixed square footprint, centered horizontally.
                bigSquare
                    .frame(width: bigSide, height: bigSide)
                    .rotationEffect(.degrees(rotation))
                    .animation(.easeInOut(duration: 0.28), value: rotation)
                    .frame(maxWidth: .infinity)

                // Bottom controls — fixed height, never rotates.
                controls
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                    .frame(height: 110)
            }
        }
    }
}

// MARK: - Logo Helpers

/// Watch logo with optional GMT hand overlay and optional dial backdrop
/// (workflow wedges). The backdrop lives inside the wheel's own geometry
/// reader so its size tracks the wheel exactly — there is no risk of it
/// changing the wheel's own layout compared to the idle screen.
struct WatchLogo: View {
    var showHand: Bool = false
    var angle: Double = 0
    var showDialBackdrop: Bool = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2

            ZStack {
                // Dial wedges sit behind the wheel, sized so their outer edge
                // is fully concealed by the wheel's rim (which is fully opaque).
                if showDialBackdrop {
                    DialWedges(size: size * 0.85)
                }

                // Wheel + hand always in same ZStack — rotate together.
                // The wheel image carries an extra +25° so one spoke sits on
                // the Buffering/Measuring boundary (~1:00); the hand is
                // unaffected by that offset, so at angle=0 it points at 12:00.
                ZStack {
                    Image("WatchBeatMark")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(25))

                    GMTHandView(radius: radius * 0.85)
                        .opacity(showHand ? 1 : 0)
                }
                .rotationEffect(.degrees(angle))

                // Dial labels sit ON TOP of the wheel so the spokes don't
                // obscure the text.
                if showDialBackdrop {
                    DialLabels(size: size * 0.90)
                }

                // 12:00 marker stays fixed
                GMTMarkerView()
                    .frame(width: 12, height: 12)
                    .offset(y: -radius - 2)
                    .opacity(showHand ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(8)
        .accessibilityHidden(true)
    }
}

// MARK: - Dial Backdrop

/// A pie slice from `startAngleCW` → `endAngleCW`, where 0° = 12:00 and
/// angles sweep clockwise.
struct Wedge: Shape {
    var startAngleCW: Double
    var endAngleCW: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let start = Angle.degrees(startAngleCW - 90)
        let end = Angle.degrees(endAngleCW - 90)
        path.move(to: center)
        path.addArc(center: center, radius: radius,
                    startAngle: start, endAngle: end, clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Colored wedges (Buffering / Measuring / Analyzing / Refining) drawn
/// behind the wheel. Angles are clock-CW from 12:00, at 6°/sec wheel pace:
/// - Buffering  0°– 30°  (12:00 → 1:00,   5 s)
/// - Measuring  30°–120°  (1:00 → 4:00,  15 s)
/// - Analyzing 120°–168°  (4:00 → ~5:36,  8 s)
/// - Refining  168°–360°  (~5:36 → 12:00, 32 s)
struct DialWedges: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Wedge(startAngleCW: 0, endAngleCW: 30)
                .fill(Color.white)
            Wedge(startAngleCW: 30, endAngleCW: 120)
                .fill(Color.blue.opacity(0.12))
            Wedge(startAngleCW: 120, endAngleCW: 168)
                .fill(Color.orange.opacity(0.12))
            Wedge(startAngleCW: 168, endAngleCW: 360)
                .fill(Color(.systemGray6))
        }
        .frame(width: size, height: size)
    }
}

/// Wedge labels drawn ON TOP of the wheel so the spokes don't obscure them.
struct DialLabels: View {
    let size: CGFloat

    var body: some View {
        let radius = size / 2
        ZStack {
            // Radial labels along each wedge midline, centered in the
            // annulus between inner hub and outer rim.
            radialLabel("Buffering", midCW: 15, radius: radius, radialFraction: 0.55)
            radialLabel("Measuring", midCW: 75, radius: radius, radialFraction: 0.55)
            radialLabel("Analyzing", midCW: 144, radius: radius, radialFraction: 0.55)

            // Refining — horizontal text at the 9:00 position (left of hub).
            Text("Refining")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(x: -radius * 0.55)
        }
        .frame(width: size, height: size)
    }

    private func radialLabel(_ text: String, midCW: Double, radius: CGFloat,
                             radialFraction: CGFloat) -> some View {
        let r = radius * radialFraction
        let theta = (midCW - 90) * .pi / 180
        let x = r * cos(CGFloat(theta))
        let y = r * sin(CGFloat(theta))
        // Outward-radial rotation — text reads from center toward the rim
        // for all wedges, matching Buffering and Measuring.
        let rotation = midCW - 90

        return Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            .rotationEffect(.degrees(rotation))
            .offset(x: x, y: y)
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
        SquareScreenLayout {
            WatchLogo()
        } bigSquare: {
            // Bullets at the top, diagram anchored to the bottom near the
            // Listen button. The square's size is fixed by SquareScreenLayout
            // so contents here never shift the wheel above.
            VStack(alignment: .leading, spacing: 10) {
                tipRow(icon: "ear", text: "Move to a quiet room away from fans, appliances, and conversation.")
                tipRow(icon: "iphone.slash", text: "If using a thick phone case, try removing it for better acoustic contact.")
                tipRow(icon: "arrow.down", text: "Hold the watch against your iPhone as shown below.")
                Image("WatchPositioningDiagram")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .accessibilityLabel("Diagram: watch caseback pressed against the bottom edge of an iPhone, crown pointing left.")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
        } controls: {
            VStack(spacing: 10) {
                ActionButton(title: "Listen") {
                    coordinator.startMonitoring()
                }
                BottomRow()
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

/// Shared caption block for the listening and measuring screens. A bold
/// position label sits above "Listening..." — when no position is
/// unambiguous, the slot stays reserved (rendered with a space) so the
/// line below never shifts. Since this block lives in ScreenLayout's
/// fixed-minHeight text slot, the wheel above it never moves either.
struct ListeningCaption: View {
    let subtitle: String
    let position: WatchPosition?

    var body: some View {
        VStack(spacing: 6) {
            Text("Position: \(position?.displayName ?? "Undefined")")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Listening...")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Persistent grip reminder pinned to the bottom-left of the controls
/// area, and (on Listening/Measuring) a centered Cancel button overlaid on
/// the same row. Fixed height so the primary action button above it lands
/// in the same vertical position on Idle, Listening, and Measuring.
struct BottomRow: View {
    var cancelAction: (() -> Void)? = nil

    var body: some View {
        ZStack {
            HStack {
                Text("← CROWN LEFT")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            if let cancel = cancelAction {
                Button("Cancel", action: cancel)
                    .foregroundStyle(.red)
            }
        }
        .frame(height: 30)
    }
}

struct MonitoringScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    var body: some View {
        TimelineView(.animation) { _ in
            let elapsed = sweepElapsed()
            let ready = elapsed >= MeasurementConstants.listenSweepDuration
            SquareScreenLayout(rotation: coordinator.latchedUIRotation) {
                WatchLogo(showHand: true,
                          angle: wheelAngle(elapsed: elapsed),
                          showDialBackdrop: true)
            } bigSquare: {
                VStack(spacing: 8) {
                    ListeningCaption(subtitle: ready
                                     ? "Look for the peak at your watch's beat rate"
                                     : "Buffering...",
                                     position: coordinator.currentPosition)
                    FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                        .frame(maxHeight: .infinity)
                }
                .padding(12)
            } controls: {
                VStack(spacing: 10) {
                    ActionButton(title: "Measure") {
                        coordinator.startMeasurement()
                    }
                    .disabled(!ready)
                    BottomRow(cancelAction: { coordinator.stopMonitoring() })
                }
            }
        }
    }

    /// Seconds since monitoring began (for the 12:00→1:00 sweep).
    private func sweepElapsed() -> Double {
        guard let start = coordinator.monitoringStartTime else { return 0 }
        return (ContinuousClock.now - start).asSeconds
    }

    /// Wheel starts at angle 0 (matching the idle screen — one spoke slightly
    /// clockwise of vertical, hand at 12:00) and sweeps to 1:00 (angle 30) over
    /// `listenSweepDuration` while the rolling buffer fills. Holds at 1:00
    /// until the user presses Measure.
    private func wheelAngle(elapsed: Double) -> Double {
        let progress = min(elapsed / MeasurementConstants.listenSweepDuration, 1.0)
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

            SquareScreenLayout(rotation: coordinator.latchedUIRotation) {
                WatchLogo(showHand: true,
                          angle: recordingWheelAngle(elapsed: elapsed),
                          showDialBackdrop: true)
            } bigSquare: {
                VStack(spacing: 8) {
                    ListeningCaption(subtitle: liveCaption(elapsed: elapsed, best: best),
                                     position: coordinator.currentPosition)
                    FrequencyBarsView(ratePowers: coordinator.ratePowers, selectedRate: nil)
                        .frame(maxHeight: .infinity)
                }
                .padding(12)
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
                    BottomRow(cancelAction: { coordinator.cancelMeasurement() })
                }
            }
        }
    }

    private func elapsedTime() -> Double {
        guard let start = coordinator.recordingStartTime else { return 0 }
        return min((ContinuousClock.now - start).asSeconds, coordinator.maxRecordingTime)
    }

    /// Wheel resumes at 1:00 (angle 30) and sweeps 330° clockwise back to
    /// 12:00 (angle 360) over `maxRecordingTime`, maintaining the same 6°/sec
    /// pace as the listening sweep.
    private func recordingWheelAngle(elapsed: Double) -> Double {
        let progress = min(elapsed / coordinator.maxRecordingTime, 1.0)
        return 30 + progress * 330
    }

    /// Caption mirrors the wheel's current wedge:
    /// - 0–15 s post-Measure: "Measuring..."
    /// - 15 s until the first result returns: "Analyzing..."
    /// - Thereafter: "Refining..."
    private func liveCaption(elapsed: Double, best: Int) -> String {
        if elapsed < MeasurementConstants.analysisWindow { return "Measuring..." }
        if best == 0 { return "Analyzing..." }
        return "Refining..."
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
                RateDialView(rateError: data.rateError,
                             beatErrorMs: data.beatErrorMs,
                             isDisorderly: data.isDisorderly,
                             watchPosition: data.watchPosition)
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

                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        TimegraphView(
                            residuals: data.tickResiduals,
                            rateErrorPerDay: data.rateError,
                            beatRateHz: Double(data.rateBPH) / 3600.0
                        )
                        .aspectRatio(1.618, contentMode: .fit)
                        Spacer(minLength: 0)
                    }
                }

                Spacer(minLength: 8)

                ActionButton(title: "Measure Again") {
                    coordinator.startMonitoring()
                }
                HStack {
                    Text("← CROWN LEFT")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.top, 6)
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
    let message: String
    @ObservedObject var coordinator: MeasurementCoordinator

    /// Mic-unavailable errors are recognized by a known prefix in the
    /// state's message string (set by MeasurementCoordinator). Only the
    /// "could not start" / permission paths qualify — a low-amplitude
    /// recording that completes is still a signal-too-weak result, not
    /// a mic availability issue.
    private var isMicUnavailable: Bool {
        message.hasPrefix("Microphone access denied")
            || message.hasPrefix("Could not start audio")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)

            if isMicUnavailable {
                micUnavailableContent
            } else {
                signalTooWeakContent
            }

            ActionButton(title: "Try Again") {
                coordinator.startMonitoring()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }

    private var micUnavailableContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "mic.slash")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Microphone unavailable")
                    .font(.title3.bold())
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 10) {
                tipRow(icon: "phone.down", text: "End any active phone or video call.")
                tipRow(icon: "waveform", text: "Quit Voice Memos or any other recording app that may be holding the microphone.")
                tipRow(icon: "lock.open", text: "Confirm WatchBeat has microphone permission in Settings → Privacy & Security → Microphone.")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var signalTooWeakContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Signal too weak")
                    .font(.title3.bold())
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 10) {
                tipRow(icon: "ear", text: "Move to a quiet room away from fans, appliances, and conversation.")
                tipRow(icon: "iphone.slash", text: "If using a thick phone case, try removing it for better acoustic contact.")
                tipRow(icon: "arrow.down", text: "Hold the watch against your iPhone as shown below.")
                tipRow(icon: "arrow.left.and.right", text: "Slide the watch slightly left or right of center to maximize the bar at your watch's beat rate.")
                tipRow(icon: "earpods", text: "Wired earbuds with a mic can pick up quiet watches better, but you'll lose automatic position detection.")

                Image("WatchPositioningDiagram")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .accessibilityLabel("Diagram: watch caseback pressed against the bottom edge of an iPhone, crown pointing left.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
