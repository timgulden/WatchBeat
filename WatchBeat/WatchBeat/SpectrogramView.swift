import SwiftUI

/// Bird-call-analyzer-style spectrogram view used on the Monitoring and
/// Recording screens.
///
/// Black-and-white grayscale rendering with darker = silent, white = high
/// energy. Time scrolls right-to-left: the rightmost column is the
/// most-recent audio, the leftmost is from 15 s ago.
///
/// Overlays:
///   - Red horizontal line at the algorithm's current best-band guess
///     (jittery during settle, calms as the recording lengthens).
///   - Pale yellow tint over the "analysis window" — the region whose
///     audio is currently being fed to the picker. During Recording,
///     this tint enters from the right and scrolls left with the
///     spectrogram, marking the audio under analysis.
///   - Orange variant of the tint when the algorithm has indicated it
///     needs additional listening time.
///
/// The view doesn't compute anything itself — it just reads from a
/// `SpectrogramData` and re-renders when the data publishes changes.
struct SpectrogramView: View {
    @ObservedObject var data: SpectrogramData

    /// 0..1 — fraction of the visible window covered by the analysis
    /// tint, growing from the right edge. 0 = no tint (Monitoring
    /// phase), 1 = full window tinted (15 s of audio under analysis).
    var analysisWindowFraction: Double = 0

    /// Tint color (yellow → orange transition handled by caller).
    var analysisTintColor: Color = Color.yellow.opacity(0.20)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                // Black background (silent regions).
                Color.black

                // Spectrogram itself.
                Canvas { ctx, size in
                    drawSpectrogram(ctx: ctx, size: size)
                }

                // Analysis-window tint.
                if analysisWindowFraction > 0 {
                    let tintWidth = w * analysisWindowFraction
                    Rectangle()
                        .fill(analysisTintColor)
                        .frame(width: tintWidth, height: h)
                        .position(x: w - tintWidth / 2, y: h / 2)
                        .blendMode(.screen)
                        .allowsHitTesting(false)
                }

                // Red best-band line.
                if let bestHz = data.bestBandHz {
                    let fracY = freqFractionFromBottom(bestHz)
                    let y = h * (1.0 - fracY)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(Color.red.opacity(0.85), lineWidth: 1.0)
                    .allowsHitTesting(false)
                }

                // Subtle frequency-axis labels on the right edge for
                // "scientific instrument" feel (4, 10, 16, 22 kHz).
                VStack(alignment: .trailing, spacing: 0) {
                    freqLabel(22)
                    Spacer()
                    freqLabel(16)
                    Spacer()
                    freqLabel(10)
                    Spacer()
                    freqLabel(4)
                }
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                .frame(width: w, height: h, alignment: .trailing)
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Render the spectrogram columns as fine vertical bars. The
    /// circular buffer is read starting from `writeIndex` (oldest
    /// column) so columns flow visually right-to-left over time.
    private func drawSpectrogram(ctx: GraphicsContext, size: CGSize) {
        let nCols = SpectrogramData.columnCount
        let nBins = SpectrogramData.binCount
        let colWidth = size.width / CGFloat(nCols)
        let binHeight = size.height / CGFloat(nBins)

        let writeIdx = data.writeIndex
        let totalCols = data.totalColumnsWritten
        // If totalColumnsWritten < nCols, only the right-side portion of
        // the canvas should show data; rest stays black.
        let visibleCount = min(totalCols, nCols)

        for visCol in 0..<visibleCount {
            // visCol = 0 is the oldest column shown (leftmost),
            // visCol = visibleCount-1 is the newest (rightmost).
            let bufIndex: Int
            if totalCols < nCols {
                // Buffer not yet wrapped; columns are at indices 0..<totalCols.
                bufIndex = visCol
            } else {
                bufIndex = (writeIdx + visCol) % nCols
            }
            // Position on screen: rightmost = newest. Leave any unfilled
            // left portion black.
            let xRight = size.width - CGFloat(visibleCount - 1 - visCol) * colWidth
            let xLeft = xRight - colWidth
            let column = data.columns[bufIndex]
            for k in 0..<nBins {
                let amp = column[k]
                guard amp > 0.02 else { continue }
                // y inverted: low frequency at bottom, high at top.
                let y = size.height - CGFloat(k + 1) * binHeight
                let rect = CGRect(x: xLeft, y: y, width: colWidth + 0.5, height: binHeight + 0.5)
                let intensity = Double(amp)
                ctx.fill(Path(rect), with: .color(.white.opacity(intensity)))
            }
        }
    }

    /// Compute the vertical fraction (0 = bottom, 1 = top) for a
    /// given frequency in Hz.
    private func freqFractionFromBottom(_ hz: Double) -> Double {
        let range = SpectrogramData.maxFreqHz - SpectrogramData.minFreqHz
        let frac = (hz - SpectrogramData.minFreqHz) / range
        return max(0, min(1, frac))
    }

    private func freqLabel(_ kHz: Int) -> some View {
        Text("\(kHz)k")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
    }
}

#Preview {
    let data = SpectrogramData()
    // Fill with a fake pattern so the preview looks like something.
    for col in 0..<SpectrogramData.columnCount {
        var c = [Float](repeating: 0, count: SpectrogramData.binCount)
        for k in 0..<SpectrogramData.binCount {
            // Horizontal stripes at common watch tick freq ranges.
            let inBand1 = abs(k - 200) < 10
            let inBand2 = abs(k - 280) < 5
            let base = inBand1 ? 0.5 : (inBand2 ? 0.7 : 0.05)
            let modulation = sin(Double(col) * 0.5 + Double(k) * 0.02) * 0.2
            c[k] = Float(max(0, base + modulation))
        }
        data.appendColumn(c)
    }
    data.bestBandHz = 14000
    return SpectrogramView(data: data, analysisWindowFraction: 0.6)
        .frame(width: 360, height: 280)
        .background(Color.gray)
        .padding()
}
