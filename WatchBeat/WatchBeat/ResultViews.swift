import SwiftUI

// MARK: - Rate Error Dial

struct RateDialView: View {
    let rateError: Double  // s/day

    // Visual range: -60 to +60 maps to 7:00 to 5:00 (300° arc)
    // Values beyond ±60 are pinned visually but show the real number
    private let maxDisplayError: Double = 60.0
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

                // Colored arc for the rate error
                if abs(rateError) > 0.5 {
                    let clampedError = max(-maxDisplayError, min(maxDisplayError, rateError))
                    let arcDegrees = (clampedError / maxDisplayError) * maxArcDegrees

                    if rateError > 0 {
                        // Fast: blue, clockwise from 12:00
                        Arc(startAngle: .degrees(-90), endAngle: .degrees(-90 + arcDegrees), clockwise: false)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .frame(width: radius * 2, height: radius * 2)
                            .position(center)
                    } else {
                        // Slow: red, counter-clockwise from 12:00
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
                VStack(spacing: 2) {
                    Text(formatError(rateError))
                        .font(.system(size: errorFontSize(rateError, dialSize: size),
                                      weight: .bold, design: .rounded))
                        .foregroundStyle(rateError > 0 ? .blue : rateError < 0 ? .red : .primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)

                    Text("s/day")
                        .font(.system(size: size * 0.08, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .position(center)

                // "FAST" / "SLOW" label
                if abs(rateError) > 0.5 {
                    Text(rateError > 0 ? "FAST" : "SLOW")
                        .font(.system(size: size * 0.06, weight: .semibold))
                        .foregroundStyle(rateError > 0 ? .blue : .red)
                        .position(x: center.x, y: center.y + radius * 0.45)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
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
        if digits <= 4 { return dialSize * 0.22 }
        if digits <= 5 { return dialSize * 0.18 }
        if digits <= 6 { return dialSize * 0.15 }
        return dialSize * 0.12
    }
}

/// An arc shape for SwiftUI.
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

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            if residuals.isEmpty {
                Text("No tick data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { context, size in
                    let maxIdx = residuals.map(\.index).max() ?? 1
                    let maxRes = max(residuals.map { abs($0.residualMs) }.max() ?? 1, 0.5)

                    // Background
                    context.fill(Path(CGRect(origin: .zero, size: size)),
                                 with: .color(Color(.systemGray6)))

                    // Center line (zero residual)
                    let centerY = h / 2
                    var centerLine = Path()
                    centerLine.move(to: CGPoint(x: 0, y: centerY))
                    centerLine.addLine(to: CGPoint(x: w, y: centerY))
                    context.stroke(centerLine, with: .color(.gray.opacity(0.3)), lineWidth: 1)

                    // Plot points — wrap horizontally
                    let beatsPerRow = max(1, maxIdx / 4)  // ~4 rows
                    let dotSize: CGFloat = 3

                    for tick in residuals {
                        let col = tick.index % beatsPerRow
                        let row = tick.index / beatsPerRow
                        let numRows = maxIdx / beatsPerRow + 1

                        let x = CGFloat(col) / CGFloat(beatsPerRow) * w
                        let rowHeight = h / CGFloat(numRows)
                        let rowCenter = rowHeight * (CGFloat(row) + 0.5)
                        let yOffset = CGFloat(tick.residualMs / maxRes) * rowHeight * 0.4
                        let y = rowCenter - yOffset  // negative = up (positive residual = above line)

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
                .frame(width: 12, height: 12)

            Text("\(percent)%")
                .font(.title3.bold().monospacedDigit())

            Text("quality")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(qualityColor.opacity(0.1))
        .cornerRadius(20)
    }

    private var qualityColor: Color {
        if percent >= 70 { return .green }
        if percent >= 40 { return .yellow }
        return .red
    }
}

// MARK: - Previews

#Preview("Dial +45") {
    RateDialView(rateError: 45)
        .frame(width: 250, height: 250)
        .padding()
}

#Preview("Dial -12") {
    RateDialView(rateError: -12)
        .frame(width: 250, height: 250)
        .padding()
}

#Preview("Dial +85") {
    RateDialView(rateError: 85.3)
        .frame(width: 250, height: 250)
        .padding()
}
