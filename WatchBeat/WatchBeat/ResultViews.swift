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
    let rateErrorPerDay: Double  // s/day, used for scaling

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

                    // The Weishi-style plot: X = time within a wrap, Y = residual.
                    // Each row wraps after a fixed time interval.
                    // Y axis = one beat period height, with residuals wrapping top-to-bottom.

                    let maxIdx = residuals.last?.index ?? 1
                    let beatsPerWrap = max(12, maxIdx / 3)  // ~3-4 rows
                    let numRows = (maxIdx / beatsPerWrap) + 1

                    // Y scale: the beat period. Residuals wrap within this.
                    // For the Y axis, use the actual residual range for better visualization.
                    let allRes = residuals.map(\.residualMs)
                    let resRange = (allRes.max() ?? 1) - (allRes.min() ?? -1)
                    let yScale = max(resRange * 1.5, 1.0)  // add some padding

                    let rowHeight = h / CGFloat(numRows)
                    let dotSize: CGFloat = 4

                    // Draw center lines for each row
                    for row in 0..<numRows {
                        let rowCenter = rowHeight * (CGFloat(row) + 0.5)
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: rowCenter))
                        line.addLine(to: CGPoint(x: w, y: rowCenter))
                        context.stroke(line, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)
                    }

                    // Plot ticks
                    for tick in residuals {
                        let col = tick.index % beatsPerWrap
                        let row = tick.index / beatsPerWrap

                        let x = (CGFloat(col) + 0.5) / CGFloat(beatsPerWrap) * w
                        let rowCenter = rowHeight * (CGFloat(row) + 0.5)

                        // Residual mapped to row height
                        let yOffset = CGFloat(tick.residualMs / yScale) * rowHeight * 0.8
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
