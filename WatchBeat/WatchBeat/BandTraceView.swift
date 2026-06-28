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

    /// Render the trace as a single Path. Log-scaled vertically. Pads
    /// with zero on the left if the buffer isn't full yet.
    private func drawTrace(ctx: GraphicsContext, size: CGSize) {
        let samples = data.visibleTrace()
        let n = samples.count
        guard n >= 2 else { return }

        // Log-scale: y = log10(1 + sample) normalized to the visible
        // window's max. Stable when energy is zero (log(1) = 0).
        var maxLog: Float = 0
        for v in samples {
            let lv = log10f(1 + max(0, v))
            if lv > maxLog { maxLog = lv }
        }
        // If everything's silent, draw a flat baseline at the bottom.
        let scale: Float = maxLog > 0 ? maxLog : 1

        let padding: CGFloat = 4
        let plotW = size.width - 2 * padding
        let plotH = size.height - 2 * padding

        var path = Path()
        for i in 0..<n {
            let x = padding + plotW * CGFloat(i) / CGFloat(n - 1)
            let lv = log10f(1 + max(0, samples[i]))
            let frac = Double(lv / scale)
            // Invert Y: high values draw near top.
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
