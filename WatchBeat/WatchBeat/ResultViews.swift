import SwiftUI
import WatchBeatCore

// MARK: - Rate Error Dial

struct RateDialView: View {
    let rateError: Double  // s/day
    let beatErrorMs: Double?  // shown in the gap at bottom
    var watchPosition: WatchPosition? = nil  // shown above the rate number

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
                    if let pos = watchPosition {
                        Text(pos.displayName)
                            .font(.system(size: size * 0.07, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)
                    }

                    Text(formatError(rateError))
                        .font(.system(size: errorFontSize(rateError, dialSize: size),
                                      weight: .bold, design: .rounded))
                        .foregroundStyle(rateError > 0 ? .blue : rateError < 0 ? .red : .primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)

                    Text("s/day")
                        .font(.system(size: size * 0.07, weight: .medium))
                        .foregroundStyle(.secondary)

                    if let tier = rateTier(rateError) {
                        Text(tier)
                            .font(.system(size: size * 0.052, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, size * 0.04)
                    } else if abs(rateError) > 0.5 {
                        Text(rateError > 0 ? "FAST" : "SLOW")
                            .font(.system(size: size * 0.055, weight: .semibold))
                            .foregroundStyle(rateError > 0 ? .blue : .red)
                    }
                }
                .position(center)

                // Beat error in the gap between 5:00 and 7:00. Low-confidence
                // results never reach this view — the coordinator routes
                // them to ErrorScreen instead.
                if let be = beatErrorMs {
                    VStack(spacing: 1) {
                        Text(String(format: "%.1f ms", be))
                            .font(.system(size: size * 0.09, weight: .bold, design: .rounded))
                            .foregroundStyle(beatErrorColor(be))
                        Text("beat error")
                            .font(.system(size: size * 0.05))
                            .foregroundStyle(.secondary)
                        Text(beatErrorLabel(be))
                            .font(.system(size: size * 0.055, weight: .semibold))
                            .foregroundStyle(beatErrorColor(be))
                    }
                    .position(x: center.x, y: center.y + radius * 0.85)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rate error")
        .accessibilityValue(rateErrorAccessibilityDescription)
    }

    private var rateErrorAccessibilityDescription: String {
        let direction = rateError > 0 ? "fast" : rateError < 0 ? "slow" : "accurate"
        var desc = "\(formatError(rateError)) seconds per day, \(direction)"
        if let tier = rateTier(rateError) {
            desc += ". \(tier)"
        }
        if let pos = watchPosition {
            desc = "Position \(pos.displayName). " + desc
        }
        if let be = beatErrorMs {
            desc += ". Beat error \(String(format: "%.1f", be)) milliseconds, \(beatErrorLabel(be).lowercased())"
        }
        return desc
    }

    /// Highest accuracy tier the measured rate qualifies for. Returns nil
    /// if the rate is outside the loosest tier (±60 s/day) — caller should
    /// fall back to the FAST/SLOW indicator. Tiers are picked from strict
    /// to lenient; chronometer-grade preserves COSC/ISO-3159's asymmetric
    /// tolerance (−4 / +6).
    private func rateTier(_ rate: Double) -> String? {
        if rate >= -4 && rate <= 6 { return "Chronometer-grade" }
        if abs(rate) <= 10 { return "Strong" }
        if abs(rate) <= 30 { return "Healthy" }
        if abs(rate) <= 60 { return "Serviceable" }
        return nil
    }

    private func beatErrorLabel(_ ms: Double) -> String {
        if ms < 1.0 { return "GOOD" }
        if ms < 3.0 { return "FAIR" }
        return "HIGH"
    }

    private func beatErrorColor(_ ms: Double) -> Color {
        if ms < 1.0 { return .green }
        if ms < 3.0 { return .orange }
        return .red
    }

    private func formatError(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(Int(value.rounded()))"
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
    let residuals: [TickTiming]
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

                    let driftPerBeatMs = rateErrorPerDay / 86400.0 / beatRateHz * 1000.0

                    // Compute all Y values (cumulative deviation)
                    var yValues = [Double]()
                    for tick in residuals {
                        let cumDrift = driftPerBeatMs * Double(tick.beatIndex)
                        yValues.append(tick.residualMs + cumDrift)
                    }

                    // Fixed Y scale: ±60 s/day over 15 seconds = ±10.4 ms.
                    // Never expands — values beyond ±60 wrap top-to-bottom.
                    let yWindowMs = 60.0 / 86400.0 * 15.0 * 1000.0 * 2.0  // 20.8ms total
                    let yCenter = ((yValues.first ?? 0) + (yValues.last ?? 0)) / 2.0

                    let centerY = h / 2.0
                    let margin: CGFloat = 4.0
                    let plotHeight = max(1, h - 2 * margin)
                    let pixPerMs = plotHeight / yWindowMs

                    // Regression line spans the first to last visible beat,
                    // representing the measured rate slope through the data.
                    let firstIdx = Double(residuals.first?.beatIndex ?? 0)
                    let lastIdx = Double(residuals.last?.beatIndex ?? 0)
                    let firstCumDrift = driftPerBeatMs * firstIdx
                    let lastCumDrift = driftPerBeatMs * lastIdx

                    let firstX: CGFloat = margin
                    let lastX: CGFloat = w - margin

                    // Bands and regression line wrap modulo yWindowMs in dev
                    // space, exactly like the dots. The regression line is
                    // split into segments at each wrap boundary so it forms a
                    // sawtooth the dots ride on.
                    let devStart = firstCumDrift - yCenter
                    let devEnd = lastCumDrift - yCenter
                    let slopeDevPerX = (lastX > firstX)
                        ? (devEnd - devStart) / Double(lastX - firstX)
                        : 0.0
                    let halfWindow = yWindowMs / 2.0

                    // Collect x-coordinates where the wrapped dev flips sign
                    // (crossings of (k + 0.5)·yWindowMs in unwrapped dev).
                    var boundaries: [CGFloat] = []
                    if abs(slopeDevPerX) > 1e-12 {
                        let devMin = min(devStart, devEnd)
                        let devMax = max(devStart, devEnd)
                        var k = Int(floor((devMin - halfWindow) / yWindowMs)) - 1
                        let kEnd = Int(ceil((devMax - halfWindow) / yWindowMs)) + 1
                        while k <= kEnd {
                            let boundary = halfWindow + Double(k) * yWindowMs
                            if boundary > devMin && boundary < devMax {
                                let xCross = firstX + CGFloat((boundary - devStart) / slopeDevPerX)
                                boundaries.append(xCross)
                            }
                            k += 1
                        }
                        boundaries.sort()
                    }
                    let segXs = [firstX] + boundaries + [lastX]

                    // Draw wrapped bands and line. Orange FAIR (±1.5 ms →
                    // 3 ms total) first, green GOOD (±0.5 ms → 1 ms total)
                    // on top, regression line on top of both.
                    func drawBand(halfWidthMs: Double, color: Color) {
                        let off = CGFloat(halfWidthMs) * pixPerMs
                        for i in 0..<(segXs.count - 1) {
                            let x0 = segXs[i]
                            let x1 = segXs[i + 1]
                            guard x1 > x0 else { continue }
                            let midX = (x0 + x1) / 2
                            let devMid = devStart + slopeDevPerX * Double(midX - firstX)
                            let kShift = (devMid / yWindowMs).rounded()
                            let dev0 = devStart + slopeDevPerX * Double(x0 - firstX) - kShift * yWindowMs
                            let dev1 = devStart + slopeDevPerX * Double(x1 - firstX) - kShift * yWindowMs
                            let y0 = centerY - CGFloat(dev0 / yWindowMs) * plotHeight
                            let y1 = centerY - CGFloat(dev1 / yWindowMs) * plotHeight
                            var p = Path()
                            p.move(to: CGPoint(x: x0, y: y0 - off))
                            p.addLine(to: CGPoint(x: x1, y: y1 - off))
                            p.addLine(to: CGPoint(x: x1, y: y1 + off))
                            p.addLine(to: CGPoint(x: x0, y: y0 + off))
                            p.closeSubpath()
                            context.fill(p, with: .color(color))
                        }
                    }

                    drawBand(halfWidthMs: 1.5, color: .orange.opacity(0.15))
                    drawBand(halfWidthMs: 0.5, color: .green.opacity(0.22))

                    for i in 0..<(segXs.count - 1) {
                        let x0 = segXs[i]
                        let x1 = segXs[i + 1]
                        guard x1 > x0 else { continue }
                        let midX = (x0 + x1) / 2
                        let devMid = devStart + slopeDevPerX * Double(midX - firstX)
                        let kShift = (devMid / yWindowMs).rounded()
                        let dev0 = devStart + slopeDevPerX * Double(x0 - firstX) - kShift * yWindowMs
                        let dev1 = devStart + slopeDevPerX * Double(x1 - firstX) - kShift * yWindowMs
                        let y0 = centerY - CGFloat(dev0 / yWindowMs) * plotHeight
                        let y1 = centerY - CGFloat(dev1 / yWindowMs) * plotHeight
                        var seg = Path()
                        seg.move(to: CGPoint(x: x0, y: y0))
                        seg.addLine(to: CGPoint(x: x1, y: y1))
                        context.stroke(seg, with: .color(.primary.opacity(0.7)), lineWidth: 0.75)
                    }


                    // Horizontal reference line (nominal / perfection)
                    var centerLine = Path()
                    centerLine.move(to: CGPoint(x: 0, y: centerY))
                    centerLine.addLine(to: CGPoint(x: w, y: centerY))
                    context.stroke(centerLine, with: .color(.gray.opacity(0.35)), lineWidth: 0.5)

                    // Plot dots
                    let dotSize: CGFloat = 3.0

                    let idxFirst = Double(residuals.first?.beatIndex ?? 0)
                    let idxLast = Double(residuals.last?.beatIndex ?? 0)
                    let idxSpan = max(idxLast - idxFirst, 1)

                    for (i, tick) in residuals.enumerated() {
                        let xFrac = (Double(tick.beatIndex) - idxFirst) / idxSpan
                        let x = margin + (w - 2 * margin) * CGFloat(xFrac)

                        // Wrap within the fixed window
                        var dev = yValues[i] - yCenter
                        let halfWindow = yWindowMs / 2.0
                        dev = dev.truncatingRemainder(dividingBy: yWindowMs)
                        if dev > halfWindow { dev -= yWindowMs }
                        if dev < -halfWindow { dev += yWindowMs }
                        let yNorm = dev / yWindowMs  // -0.5 to +0.5
                        let y = centerY - CGFloat(yNorm) * plotHeight

                        let color: Color = tick.isEvenBeat ? .blue : .cyan
                        let rect = CGRect(x: x - dotSize/2, y: y - dotSize/2,
                                          width: dotSize, height: dotSize)
                        context.fill(Ellipse().path(in: rect), with: .color(color))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Timegraph")
                .accessibilityValue("\(residuals.count) ticks plotted")
            }
        }
    }
}

// MARK: - Quality Badge

struct QualityBadgeView: View {
    let percent: Int

    private var color: Color { MeasurementConstants.qualityColor(percent) }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            Text("\(percent)%")
                .font(.subheadline.bold().monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .cornerRadius(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quality")
        .accessibilityValue("\(percent) percent, \(qualityDescription)")
    }

    private var qualityDescription: String {
        if percent >= 50 { return "good" }
        if percent >= 30 { return "fair" }
        return "poor"
    }
}

// MARK: - GMT Hand and Marker

/// A GMT-style watch hand: elongated with an arrow tip.
struct GMTHandView: View {
    let radius: CGFloat

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let tipY = center.y - radius
            let tailY = center.y + radius * 0.15
            let halfWidth: CGFloat = 1.5
            let arrowWidth: CGFloat = 8
            let arrowStart = tipY + 16

            var path = Path()
            // Arrow tip
            path.move(to: CGPoint(x: center.x, y: tipY))
            path.addLine(to: CGPoint(x: center.x - arrowWidth, y: arrowStart))
            path.addLine(to: CGPoint(x: center.x - halfWidth, y: arrowStart))
            // Shaft
            path.addLine(to: CGPoint(x: center.x - halfWidth, y: tailY))
            path.addLine(to: CGPoint(x: center.x + halfWidth, y: tailY))
            path.addLine(to: CGPoint(x: center.x + halfWidth, y: arrowStart))
            // Arrow tip other side
            path.addLine(to: CGPoint(x: center.x + arrowWidth, y: arrowStart))
            path.closeSubpath()

            context.fill(path, with: .color(.black))
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

/// A small inverted triangle marker at the 12:00 position, pointing down.
struct GMTMarkerView: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: size.width / 2, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: 0))
            path.closeSubpath()
            context.fill(path, with: .color(.black))
        }
    }
}

#Preview("Dial +77") {
    RateDialView(rateError: 77, beatErrorMs: 1.6)
        .frame(width: 250, height: 250)
        .padding()
}
