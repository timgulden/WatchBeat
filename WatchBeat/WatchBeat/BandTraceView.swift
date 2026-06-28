import SwiftUI

/// EKG-style line plot of the best-band energy over the last 15 seconds.
/// New audio enters from the right edge; old samples age to the left.
///
/// Y-axis: log magnitude, scaled adaptively to the loudest sample in the
/// visible window. Each tick of the watch shows up as a clear spike;
/// quiet regions sit near the bottom.
struct BandTraceView: View {
    @ObservedObject var data: SpectrogramData

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                // White background — instrument aesthetic.
                Color.white

                // Trace.
                Canvas { ctx, size in
                    drawTrace(ctx: ctx, size: size)
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
            )
            .frame(width: w, height: h)
        }
    }

    /// Render the trace as a single Path. Log-scaled vertically.
    ///
    /// Fill behavior: trace grows from LEFT to right as samples
    /// accumulate during the first 15 seconds. Once the buffer is
    /// full (totalTraceWritten ≥ traceSampleCount), the trace spans
    /// the full width and scrolls left as new samples arrive.
    private func drawTrace(ctx: GraphicsContext, size: CGSize) {
        let allSamples = data.visibleTrace()        // 300 entries, padded left with zeros
        let total = data.totalTraceWritten
        let count = SpectrogramData.traceSampleCount
        let realCount = min(total, count)
        guard realCount >= 2 else { return }

        // Slice out just the real (non-padded) samples.
        let realSamples = Array(allSamples[(count - realCount)..<count])

        // Log-scale, normalized to the visible window's max.
        var maxLog: Float = 0
        for v in realSamples {
            let lv = log10f(1 + max(0, v))
            if lv > maxLog { maxLog = lv }
        }
        let scale: Float = maxLog > 0 ? maxLog : 1

        let padding: CGFloat = 4
        let plotW = size.width - 2 * padding
        let plotH = size.height - 2 * padding

        // X mapping: sample index i ∈ [0, count) maps linearly across
        // plotW. Partial-fill samples land in the left portion; once
        // full, they span the whole width (and older samples scroll
        // off as new ones arrive via the circular buffer).
        var path = Path()
        for i in 0..<realCount {
            let x = padding + plotW * CGFloat(i) / CGFloat(count - 1)
            let lv = log10f(1 + max(0, realSamples[i]))
            let frac = Double(lv / scale)
            let y = padding + plotH * (1.0 - CGFloat(frac))
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        ctx.stroke(path, with: .color(.black), lineWidth: 1.0)
    }
}
