import SwiftUI

// MARK: - Logo

/// Watch logo with optional GMT hand overlay and optional dial backdrop
/// (workflow wedges). The backdrop lives inside the wheel's own geometry
/// reader so its size tracks the wheel exactly — there is no risk of it
/// changing the wheel's own layout compared to the idle screen.
struct WatchLogo: View {
    var showHand: Bool = false
    var angle: Double = 0
    var showDialBackdrop: Bool = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2

            ZStack {
                // Dial wedges sit behind the wheel, sized so their outer edge
                // is fully concealed by the wheel's rim (which is fully opaque).
                // Pass the current hand angle so the wedge containing it gets
                // a deeper tint — visual signal of which workflow phase we're
                // in without reading labels.
                if showDialBackdrop {
                    DialWedges(size: size * 0.85, handAngleCW: angle)
                }

                // Wheel + hand always in same ZStack — rotate together.
                // The wheel image carries an extra +25° so one spoke sits on
                // the Listening/Measuring boundary (~1:00); the hand is
                // unaffected by that offset, so at angle=0 it points at 12:00.
                //
                // The .shadow modifier sits OUTSIDE the rotationEffect so the
                // shadow direction stays fixed in screen coordinates (light
                // source above the wheel). This lets the shadow appear to
                // change as the dial rotates beneath it — a small but
                // tactile detail that grounds the wheel as a physical object.
                ZStack {
                    Image("WatchBeatMark")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(25))

                    GMTHandView(radius: radius * 0.85)
                        .opacity(showHand ? 1 : 0)
                }
                .rotationEffect(.degrees(angle))
                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 3)

                // Dial labels sit ON TOP of the wheel so the spokes don't
                // obscure the text.
                if showDialBackdrop {
                    DialLabels(size: size * 0.90)
                }

                // 12:00 marker stays fixed
                GMTMarkerView()
                    .frame(width: 12, height: 12)
                    .offset(y: -radius - 2)
                    .opacity(showHand ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(8)
        .accessibilityHidden(true)
    }
}

// MARK: - Dial Backdrop

/// A pie slice from `startAngleCW` → `endAngleCW`, where 0° = 12:00 and
/// angles sweep clockwise.
struct Wedge: Shape {
    var startAngleCW: Double
    var endAngleCW: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let start = Angle.degrees(startAngleCW - 90)
        let end = Angle.degrees(endAngleCW - 90)
        path.move(to: center)
        path.addArc(center: center, radius: radius,
                    startAngle: start, endAngle: end, clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Colored wedges (Measuring / Analyzing / Refining) drawn behind the
/// wheel. Angles are clock-CW from 12:00, at 6°/sec wheel pace:
/// - Measuring   0°– 90°  (12:00 → 3:00,  15 s)
/// - Analyzing  90°–108°  (3:00 → ~3:36,  3 s — slim slice; user sees the
///                         color shift before transitioning to Refining)
/// - Refining  108°–360°  (~3:36 → 12:00, 42 s)
///
/// Pre-Measure (monitoring): the wheel sits at 12:00 (angle 0). Bars
/// grow in the panel above as the FFT window fills. No Listening wedge —
/// the grow-window FFT shows useful data immediately, gated by a 3 s
/// disable on the Measure button rather than a sweep animation.
///
/// The currently-active wedge (the one containing the hand's current angle)
/// is rendered with a deeper tint so the user sees the workflow phase
/// without reading labels.
struct DialWedges: View {
    let size: CGFloat
    /// Current hand angle in degrees CW from 12:00. The wedge containing
    /// this angle gets the active (deeper) tint.
    var handAngleCW: Double = 0

    var body: some View {
        let active = activeWedge(forAngle: handAngleCW)
        ZStack {
            Wedge(startAngleCW: 0, endAngleCW: 90)
                .fill(Color.blue.opacity(active == .measuring ? 0.22 : 0.12))
            Wedge(startAngleCW: 90, endAngleCW: 108)
                .fill(Color.orange.opacity(active == .analyzing ? 0.32 : 0.18))
            Wedge(startAngleCW: 108, endAngleCW: 360)
                .fill(active == .refining ? refiningColorActive : refiningColorIdle)
        }
        .frame(width: size, height: size)
    }

    private enum Phase { case measuring, analyzing, refining }
    private func activeWedge(forAngle a: Double) -> Phase {
        let normalized = (a.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        switch normalized {
        case ..<90:    return .measuring
        case ..<108:   return .analyzing
        default:       return .refining
        }
    }
    // Refining base is systemGray6; "active" is systemGray5.
    private var refiningColorIdle: Color { Color(.systemGray6) }
    private var refiningColorActive: Color { Color(.systemGray5) }
}

/// Wedge labels drawn ON TOP of the wheel so the spokes don't obscure them.
struct DialLabels: View {
    let size: CGFloat

    var body: some View {
        let radius = size / 2
        ZStack {
            // Radial labels along each wedge midline, centered in the
            // annulus between inner hub and outer rim.
            // Analyzing wedge is small (18°), but its label still emanates
            // from its center (99°) — text spilling slightly into the
            // neighboring wedges is fine; the color shift signals the phase.
            radialLabel("Measuring", midCW: 45, radius: radius, radialFraction: 0.55)
            radialLabel("Analyzing", midCW: 99, radius: radius, radialFraction: 0.55)

            // Refining — horizontal text at the 9:00 position (left of hub).
            Text("Refining")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(x: -radius * 0.55)
        }
        .frame(width: size, height: size)
    }

    private func radialLabel(_ text: String, midCW: Double, radius: CGFloat,
                             radialFraction: CGFloat) -> some View {
        let r = radius * radialFraction
        let theta = (midCW - 90) * .pi / 180
        let x = r * cos(CGFloat(theta))
        let y = r * sin(CGFloat(theta))
        // Outward-radial rotation — text reads from center toward the rim
        // for all wedges, matching Listening and Measuring.
        let rotation = midCW - 90

        return Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            .rotationEffect(.degrees(rotation))
            .offset(x: x, y: y)
    }
}
