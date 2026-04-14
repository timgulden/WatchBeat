import SwiftUI

// MARK: - Rate Error Dial

struct RateDialView: View {
    let rateError: Double  // s/day
    let beatErrorMs: Double?  // shown in the gap at bottom

    private let maxDisplayError: Double = 120.0
    private let maxArcDegrees: Double = 150.0  // each direction from 12:00

    var body: some View {
        GeometryReader { geo in
            let size = max(1, min(geo.size.width, geo.size.height))
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = max(1, size * 0.42)
            let lineWidth = max(1, size * 0.06)

            ZStack {
                // Background track (7:00 to 5:00 going through 12:00)
                Arc(startAngle: .degrees(120), endAngle: .degrees(60), clockwise: false)
                    .stroke(Color(.systemGray5), lineWidth: lineWidth)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                // Colored arc
                if abs(rateError) > 0.5 {
                    let clampedError = max(-maxDisplayError, min(maxDisplayError, rateError))
                    let arcDegrees = (clampedError / maxDisplayError) * maxArcDegrees

                    if rateError > 0 {
                        Arc(startAngle: .degrees(-90), endAngle: .degrees(-90 + arcDegrees), clockwise: false)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .frame(width: radius * 2, height: radius * 2)
                            .position(center)
                    } else {
                        Arc(startAngle: .degrees(-90 + arcDegrees), endAngle: .degrees(-90), clockwise: false)
                            .stroke(Color.red, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .frame(width: radius * 2, height: radius * 2)
                            .position(center)
                    }
                }

                // White marker at 12:00
                Circle()
                    .fill(.white)
                    .frame(width: lineWidth * 1.5, height: lineWidth * 1.5)
                    .position(x: center.x, y: center.y - radius)

                // Rate error number in the center
                VStack(spacing: 0) {
                    Text(formatError(rateError))
                        .font(.system(size: errorFontSize(rateError, dialSize: size),
                                      weight: .bold, design: .rounded))
                        .foregroundStyle(rateError > 0 ? .blue : rateError < 0 ? .red : .primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)

                    Text("s/day")
                        .font(.system(size: size * 0.07, weight: .medium))
                        .foregroundStyle(.secondary)

                    if abs(rateError) > 0.5 {
                        Text(rateError > 0 ? "FAST" : "SLOW")
                            .font(.system(size: size * 0.055, weight: .semibold))
                            .foregroundStyle(rateError > 0 ? .blue : .red)
                    }
                }
                .position(center)

                // Beat error in the gap between 5:00 and 7:00
                if let be = beatErrorMs {
                    VStack(spacing: 1) {
                        Text(String(format: "%.1f ms", be))
                            .font(.system(size: size * 0.09, weight: .bold, design: .rounded))
                            .foregroundStyle(beatErrorColor(be))
                        Text("beat error")
                            .font(.system(size: size * 0.05))
                            .foregroundStyle(.secondary)
                    }
                    .position(x: center.x, y: center.y + radius * 0.85)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func beatErrorColor(_ ms: Double) -> Color {
        if ms < 1.0 { return .green }
        if ms < 3.0 { return .orange }
        return .red
    }

    private func formatError(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        if abs(value) >= 100 {
            return "\(sign)\(Int(value))"
        }
        return "\(sign)\(String(format: "%.1f", value))"
    }

    private func errorFontSize(_ value: Double, dialSize: CGFloat) -> CGFloat {
        let digits = formatError(value).count
        if digits <= 4 { return dialSize * 0.20 }
        if digits <= 5 { return dialSize * 0.17 }
        if digits <= 6 { return dialSize * 0.14 }
        return dialSize * 0.11
    }
}

struct Arc: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let clockwise: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: rect.width / 2,
                    startAngle: startAngle, endAngle: endAngle,
                    clockwise: clockwise)
        return path
    }
}

// MARK: - Timegraph

struct TimegraphView: View {
    let residuals: [(index: Int, residualMs: Double, isEven: Bool)]
    let rateErrorPerDay: Double
    let beatRateHz: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            if residuals.count < 3 {
                Text("Insufficient data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { context, size in
                    // Background
                    context.fill(Path(CGRect(origin: .zero, size: size)),
                                 with: .color(Color(.systemGray6)))

                    // Single row, no wrapping. Every tick from the 15-second
                    // window is one dot, spread left to right.
                    //
                    // Y axis: cumulative deviation from nominal position.
                    // Rate error creates a slope; beat error creates tick/tock separation.
                    //
                    // The residuals from regression have the slope removed.
                    // We add it back for the visual so the user sees the drift.

                    let n = residuals.count
                    let driftPerBeatMs = rateErrorPerDay / 86400.0 / beatRateHz * 1000.0

                    // Compute all Y values (cumulative deviation)
                    var yValues = [Double]()
                    for tick in residuals {
                        let cumDrift = driftPerBeatMs * Double(tick.index)
                        yValues.append(tick.residualMs + cumDrift)
                    }

                    // Fixed Y scale: ±60 s/day over 15 seconds = ±10.4 ms.
                    // Never expands — values beyond ±60 wrap top-to-bottom.
                    let yWindowMs = 60.0 / 86400.0 * 15.0 * 1000.0 * 2.0  // 20.8ms total
                    let yCenter = (yValues.first ?? 0 + (yValues.last ?? 0)) / 2.0

                    // Center line
                    let centerY = h / 2.0
                    var centerLine = Path()
                    centerLine.move(to: CGPoint(x: 0, y: centerY))
                    centerLine.addLine(to: CGPoint(x: w, y: centerY))
                    context.stroke(centerLine, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)

                    // Plot dots
                    let dotSize: CGFloat = 3.0
                    let margin: CGFloat = 4.0

                    for (i, tick) in residuals.enumerated() {
                        let x = margin + (w - 2 * margin) * CGFloat(i) / CGFloat(max(n - 1, 1))

                        // Wrap within the fixed window
                        var dev = yValues[i] - yCenter
                        let halfWindow = yWindowMs / 2.0
                        dev = dev.truncatingRemainder(dividingBy: yWindowMs)
                        if dev > halfWindow { dev -= yWindowMs }
                        if dev < -halfWindow { dev += yWindowMs }
                        let yNorm = dev / yWindowMs  // -0.5 to +0.5
                        let y = centerY - CGFloat(yNorm) * max(1, h - 2 * margin)

                        let color: Color = tick.isEven ? .blue : .cyan
                        let rect = CGRect(x: x - dotSize/2, y: y - dotSize/2,
                                          width: dotSize, height: dotSize)
                        context.fill(Ellipse().path(in: rect), with: .color(color))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Quality Badge

struct QualityBadgeView: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(qualityColor)
                .frame(width: 10, height: 10)

            Text("\(percent)%")
                .font(.subheadline.bold().monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(qualityColor.opacity(0.1))
        .cornerRadius(16)
    }

    private var qualityColor: Color {
        if percent >= 50 { return .green }
        if percent >= 30 { return .orange }
        return .red
    }
}

#Preview("Dial +77") {
    RateDialView(rateError: 77, beatErrorMs: 1.6)
        .frame(width: 250, height: 250)
        .padding()
}
