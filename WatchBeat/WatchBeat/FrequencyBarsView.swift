import SwiftUI
import WatchBeatCore

struct FrequencyBarsView: View {
    let ratePowers: [StandardBeatRate: Float]
    let selectedRate: StandardBeatRate?

    private let rates = StandardBeatRate.allCases

    var body: some View {
        let maxPower = ratePowers.values.max() ?? 1.0

        GeometryReader { geo in
            // Two-line label: bph (e.g. "18,000") above oscillation Hz
            // (e.g. "2.5 Hz"). bph appears with no unit suffix to save
            // horizontal space; the Hz line carries the unit.
            let labelHeight: CGFloat = 30
            let barAreaHeight = max(10, geo.size.height - labelHeight - 4)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(rates, id: \.self) { rate in
                    let power = ratePowers[rate] ?? 0
                    let normalizedHeight = maxPower > 0 ? CGFloat(power / maxPower) : 0
                    let isStrongest = power == maxPower && maxPower > 0 && power > 0

                    VStack(spacing: 2) {
                        Spacer(minLength: 0)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(isStrongest ? Color.green : Color.blue)
                            .frame(height: max(2, normalizedHeight * barAreaHeight))

                        VStack(spacing: 0) {
                            Text(formatBph(rate.rawValue))
                                .font(.system(size: 10, weight: isStrongest ? .bold : .regular))
                                .foregroundStyle(isStrongest ? .primary : .secondary)
                            Text("\(formatOscHz(rate.oscillationHz)) Hz")
                                .font(.system(size: 10, weight: isStrongest ? .bold : .regular))
                                .foregroundStyle(isStrongest ? .primary : .secondary)
                        }
                        .frame(height: labelHeight)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(rate.rawValue) beats per hour, \(formatOscHz(rate.oscillationHz)) hertz")
                    .accessibilityValue(isStrongest ? "strongest signal" : "\(Int(normalizedHeight * 100)) percent")
                }
            }
        }
    }
}

/// Format bph as a thousands-grouped integer (e.g. 18000 → "18,000").
/// Uses the user's locale for the grouping separator — most English
/// locales use comma; some European locales use period or space.
private func formatBph(_ bph: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSNumber(value: bph)) ?? "\(bph)"
}

/// Format oscillation Hz for display — shows decimal for non-integer values like 2.75.
func formatOscHz(_ hz: Double) -> String {
    if hz == hz.rounded() { return "\(Int(hz))" }
    let oneDecimal = String(format: "%.1f", hz)
    if Double(oneDecimal) == hz { return oneDecimal }
    return String(format: "%.2f", hz)
}
