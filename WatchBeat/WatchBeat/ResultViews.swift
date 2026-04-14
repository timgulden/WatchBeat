import SwiftUI

// MARK: - Rate Error Dial

struct RateDialView: View {
    let rateError: Double  // s/day
    let beatErrorMs: Double?  // shown in the gap at bottom

    private let maxDisplayError: Double = 120.0
    private let maxArcDegrees: Double = 150.0  // each direction from 12:00

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size * 0.42
            let lineWidth = size * 0.06

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

// MARK: - Timegrapher Plot

struct TimegrapherPlotView: View {
    let residuals: [(index: Int, residualMs: Double, isEven: Bool)]
    let rateErrorPerDay: Double
    let beatRateHz: Double

    // Y axis represents ±60 s/day of cumulative deviation.
    // This matches the Weishi style where each row is one beat period
    // and drift causes the dots to slope up (fast) or down (slow),
    // wrapping when they reach the edge.
    private let yAxisSecondsPerDay: Double = 60.0

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

                    // Weishi-style: X = time within wrap, Y = cumulative deviation
                    // that wraps at ±yAxisWindow.
                    //
                    // The Y window = how much cumulative deviation fits in the plot.
                    // For 60 s/day at this beat rate over 15 seconds:
                    //   drift per second = 60/86400 = 0.000694 s = 0.694 ms
                    //   drift in 15 seconds = 10.4 ms
                    //   drift per beat = 0.694 / beatRateHz ms
                    //
                    // The Y axis window should be one beat period in ms,
                    // and dots wrap when cumulative deviation exceeds it.
                    let beatPeriodMs = 1000.0 / beatRateHz
                    let yWindowMs = beatPeriodMs  // one full beat period

                    // Wrap width: ~2 seconds of beats
                    let beatsPerWrap = max(8, Int(beatRateHz * 2))
                    let maxIdx = residuals.last?.index ?? 1
                    let numRows = max(1, (maxIdx / beatsPerWrap) + 1)

                    let rowHeight = h / CGFloat(numRows)
                    let dotSize: CGFloat = 3.5

                    // Draw faint center lines
                    for row in 0..<numRows {
                        let y = rowHeight * (CGFloat(row) + 0.5)
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: y))
                        line.addLine(to: CGPoint(x: w, y: y))
                        context.stroke(line, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
                    }

                    // Plot using regression residuals directly.
                    // The residuals already have the regression slope removed,
                    // so a perfect watch shows a flat line and beat error shows
                    // as tick/tock separation. The rate error is in the slope
                    // which we add back as cumulative drift for the visual.
                    let driftPerBeatMs = rateErrorPerDay / 86400.0 / beatRateHz * 1000.0

                    for tick in residuals {
                        let col = tick.index % beatsPerWrap
                        let row = tick.index / beatsPerWrap

                        let x = (CGFloat(col) + 0.5) / CGFloat(beatsPerWrap) * w

                        // Add back the rate error drift for the visual slope
                        let cumulativeDriftMs = driftPerBeatMs * Double(col)
                        let totalDevMs = tick.residualMs + cumulativeDriftMs

                        // Wrap within ±yWindowMs/2
                        var wrapped = totalDevMs.truncatingRemainder(dividingBy: yWindowMs)
                        if wrapped > yWindowMs / 2 { wrapped -= yWindowMs }
                        if wrapped < -yWindowMs / 2 { wrapped += yWindowMs }

                        let rowCenter = rowHeight * (CGFloat(row) + 0.5)
                        let yOffset = CGFloat(wrapped / yWindowMs) * rowHeight
                        let y = rowCenter - yOffset

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

            Text("quality")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(qualityColor.opacity(0.1))
        .cornerRadius(16)
    }

    private var qualityColor: Color {
        if percent >= 70 { return .green }
        if percent >= 40 { return .yellow }
        return .red
    }
}

#Preview("Dial +77") {
    RateDialView(rateError: 77, beatErrorMs: 1.6)
        .frame(width: 250, height: 250)
        .padding()
}
