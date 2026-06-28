import SwiftUI
import WatchBeatCore

/// Vertical bar chart of Goertzel magnitudes at each standard mechanical
/// beat rate, computed from the trace data (best-band energy). The bar
/// at the actual beat rate stands out; diffuse bars mean no rhythm has
/// been detected.
///
/// One bar per StandardBeatRate (5, 5.5, 6, 7, 8, 10 Hz). The strongest
/// bar is highlighted in color; the others render dimmer for contrast.
/// Labels beneath each bar show "bph/Hz" (e.g., "18k 5Hz").
struct BeatRateBarsView: View {
    @ObservedObject var data: SpectrogramData

    private let rates: [StandardBeatRate] = StandardBeatRate.allCases

    var body: some View {
        // Identify the dominant rate (if any signal at all).
        let dominantRate = data.rateMagnitudes.max(by: { $0.value < $1.value })?.key

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let labelHeight: CGFloat = 22
            let barAreaHeight = max(0, h - labelHeight)
            let barCount = rates.count
            let spacing: CGFloat = 6
            let barWidth = max(8, (w - spacing * CGFloat(barCount + 1)) / CGFloat(barCount))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(rates.enumerated()), id: \.offset) { _, rate in
                    let mag = data.rateMagnitudes[rate] ?? 0
                    let isDominant = (rate == dominantRate) && mag > 0.05
                    VStack(spacing: 2) {
                        ZStack(alignment: .bottom) {
                            // Background (light gray = track).
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gray.opacity(0.18))
                                .frame(width: barWidth, height: barAreaHeight)
                            // Filled portion.
                            RoundedRectangle(cornerRadius: 2)
                                .fill(isDominant ? Color.accentColor : Color.secondary)
                                .frame(width: barWidth,
                                       height: max(2, barAreaHeight * CGFloat(mag)))
                        }
                        Text(barLabel(for: rate))
                            .font(.system(size: 9, weight: isDominant ? .bold : .regular,
                                          design: .monospaced))
                            .foregroundStyle(isDominant ? Color.accentColor : .secondary)
                            .lineLimit(1)
                            .frame(width: barWidth + 4)
                    }
                }
            }
            .padding(.horizontal, spacing)
            .frame(width: w, height: h, alignment: .bottom)
        }
    }

    /// "18k" for 18000 bph, or formatted oscillation Hz.
    private func barLabel(for rate: StandardBeatRate) -> String {
        let k = rate.rawValue / 1000
        return "\(k)k"
    }
}
