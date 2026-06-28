import SwiftUI
import CoreGraphics

/// Bird-call-analyzer-style spectrogram view used on the Monitoring and
/// Recording screens.
///
/// Bitmap-rendered for speed: each body re-eval builds a small
/// (columnCount × binCount) grayscale CGImage from the spectrogram data
/// and displays it scaled to the view size. Far faster than the previous
/// Canvas-based renderer that drew one filled rect per (column × bin)
/// cell — Canvas could not sustain even the 13 Hz update rate, so the
/// column-tied analysis tint lagged behind wall-clock time.
///
/// Time scrolls right-to-left: the rightmost pixel column is the most-
/// recent audio, the leftmost is from 15 s ago. Dark ink on white
/// background.
///
/// Overlays drawn on top of the bitmap:
///   - Red horizontal line at the algorithm's current best-band guess.
///   - Pale yellow / orange / green tint over the analysis window;
///     width comes from `data.analysisWindowFraction` so the tint
///     advances exactly one step when a new spectrogram column is
///     appended, keeping it in lockstep with the spectrogram itself.
struct SpectrogramView: View {
    @ObservedObject var data: SpectrogramData

    /// Tint color over the analysis window. The width of the tint comes
    /// from `data.analysisWindowFraction` (column-tied — moves in
    /// lockstep with the spectrogram). Caller controls only the color
    /// so different screens can use different hues (yellow during
    /// recording, green for the "Success" pause, orange when extra
    /// listening is needed, etc.).
    var analysisTintColor: Color = Color.yellow.opacity(0.25)

    var body: some View {
        let tintFraction = data.analysisWindowFraction

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                // White background — bird-call-analyzer aesthetic.
                Color.white

                // Spectrogram bitmap. Built from the data each render
                // (cheap: ~30 000 pixel writes), wrapped in a CGImage
                // and displayed via Image — the heavy lifting goes to
                // the GPU.
                if let image = makeSpectrogramImage() {
                    Image(decorative: image, scale: 1.0, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: w, height: h)
                        .allowsHitTesting(false)
                }

                // Analysis-window tint. Width comes from the column-tied
                // fraction so it advances one step exactly when a new
                // spectrogram column appears.
                if tintFraction > 0 {
                    let tintWidth = w * CGFloat(tintFraction)
                    Rectangle()
                        .fill(analysisTintColor)
                        .frame(width: tintWidth, height: h)
                        .position(x: w - tintWidth / 2, y: h / 2)
                        .blendMode(.multiply)
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
                // "scientific instrument" feel.
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
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    /// Build the spectrogram as a small RGBA bitmap. Each pixel = one
    /// (column, bin) cell. Brightness inverted so 0 (silent) is white
    /// and 1 (full energy) is black.
    private func makeSpectrogramImage() -> CGImage? {
        let width = SpectrogramData.columnCount
        let height = SpectrogramData.binCount
        let bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height

        // Allocate the pixel buffer (filled with white = 0xFF). Direct
        // pointer writes inside withUnsafeMutableBytes — fast enough
        // that we can afford to rebuild every render.
        var pixels = [UInt8](repeating: 0xFF, count: totalBytes)
        pixels.withUnsafeMutableBufferPointer { buf in
            guard let p = buf.baseAddress else { return }

            let totalCols = data.totalColumnsWritten
            let writeIdx = data.writeIndex
            let visibleCount = min(totalCols, width)

            for visCol in 0..<visibleCount {
                let bufIndex: Int
                if totalCols < width {
                    bufIndex = visCol
                } else {
                    bufIndex = (writeIdx + visCol) % width
                }
                // visCol=0 is the OLDEST visible column. We want it on
                // the LEFT, so the rightmost pixel column corresponds
                // to the newest. The offset from the left edge is:
                // (visCol + width - visibleCount) gives pixel column.
                let pixelCol = (width - visibleCount) + visCol
                let column = data.columns[bufIndex]
                for k in 0..<height {
                    let amp = column[k]
                    guard amp > 0.01 else { continue }
                    let intensity = max(0, min(255, Int(amp * 255)))
                    let pixelValue = UInt8(255 - intensity)
                    // Flip vertical: high freq at top, low at bottom.
                    let y = height - 1 - k
                    let offset = (y * width + pixelCol) * 4
                    p[offset + 0] = pixelValue  // R
                    p[offset + 1] = pixelValue  // G
                    p[offset + 2] = pixelValue  // B
                    // alpha stays 0xFF (initialized).
                }
            }
        }

        // Wrap the pixel buffer in a CGImage. The Data copy is cheap
        // (small buffer); CGDataProvider takes ownership.
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
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
            .foregroundStyle(.black.opacity(0.55))
    }
}
