import SwiftUI
import WatchBeatCore

struct ResultScreen: View {
    let data: MeasurementCoordinator.MeasurementDisplayData
    @ObservedObject var coordinator: MeasurementCoordinator
    @State private var liftAngleText: String = ""
    @FocusState private var liftAngleFocused: Bool
    @State private var showLiftAngleInfo = false

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

                // Dial. Result screen never shows a low-confidence result —
                // the coordinator routes those to ErrorScreen. So we can
                // assume isLowConfidence is always false here.
                RateDialView(rateError: data.rateError,
                             beatErrorMs: data.beatErrorMs,
                             watchPosition: data.watchPosition)
                    .frame(maxHeight: 310)
                    .padding(.top, -8)

                // Lift Angle / Amplitude row
                if data.pulseWidths != nil {
                    HStack(alignment: .top) {
                        // Lift Angle input (left)
                        VStack(spacing: 2) {
                            HStack(spacing: 4) {
                                Text("Lift Angle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    showLiftAngleInfo = true
                                } label: {
                                    Image(systemName: "info.circle")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                                .accessibilityLabel("About lift angle")
                            }
                            HStack(spacing: 2) {
                                TextField("", text: $liftAngleText)
                                    .keyboardType(.decimalPad)
                                    .submitLabel(.done)
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
                                    .onSubmit { liftAngleFocused = false }
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
                            residuals: data.tickTimings,
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
        // Tap anywhere on the screen background to dismiss the keyboard
        // when the lift-angle field is focused. Belt-and-suspenders for
        // the keyboard toolbar Done button below: SwiftUI's keyboard-
        // placement toolbar occasionally fails to render (especially in
        // combination with .ignoresSafeArea(.keyboard)), leaving users
        // with no way to dismiss the keyboard. The simultaneousGesture
        // doesn't block child button taps — they still fire normally.
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                if liftAngleFocused { liftAngleFocused = false }
            }
        )
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
        .sheet(isPresented: $showLiftAngleInfo) {
            LiftAngleInfoScreen()
        }
    }
}
