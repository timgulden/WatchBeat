import SwiftUI
import WatchBeatCore

/// Format bph as a thousands-grouped integer (e.g. 18000 → "18,000").
private func formatBph(_ bph: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSNumber(value: bph)) ?? "\(bph)"
}

/// Vertical bar chart of Goertzel magnitudes at each standard mechanical
/// beat rate, computed from the trace data (best-band energy over the
/// last 5 s). The bar at the actual beat rate stands out; diffuse bars
/// mean no rhythm has been detected.
///
/// Bars on a clean white background (no gray "track" behind unfilled
/// portion). Color follows the prior FrequencyBarsView convention —
/// strongest is green, others are blue.
struct BeatRateBarsView: View {
    @ObservedObject var data: SpectrogramData

    private let rates: [StandardBeatRate] = StandardBeatRate.allCases

    var body: some View {
        let dominantRate = data.rateMagnitudes.max(by: { $0.value < $1.value })?.key

        GeometryReader { geo in
            let labelHeight: CGFloat = 30
            let barAreaHeight = max(10, geo.size.height - labelHeight - 4)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(rates, id: \.self) { rate in
                    let mag = data.rateMagnitudes[rate] ?? 0
                    let isDominant = (rate == dominantRate) && mag > 0.05

                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        // Bar only — no background track. Sits flush against
                        // the white parent background.
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isDominant ? Color.green : Color.blue)
                            .frame(height: max(2, CGFloat(mag) * barAreaHeight))
                        // Two-line label: bph above oscillation Hz.
                        VStack(spacing: 0) {
                            Text(formatBph(rate.rawValue))
                                .font(.system(size: 10, weight: isDominant ? .bold : .regular))
                                .foregroundStyle(isDominant ? .primary : .secondary)
                            Text("\(formatOscHz(rate.oscillationHz)) Hz")
                                .font(.system(size: 10, weight: isDominant ? .bold : .regular))
                                .foregroundStyle(isDominant ? .primary : .secondary)
                        }
                        .frame(height: labelHeight)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(rate.rawValue) beats per hour, \(formatOscHz(rate.oscillationHz)) hertz")
                    .accessibilityValue(isDominant ? "strongest signal" : "\(Int(mag * 100)) percent")
                }
            }
            .padding(.horizontal, 6)
        }
    }
}
