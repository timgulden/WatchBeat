import SwiftUI

/// Two-square layout used by idle, listening, and measuring screens.
///
/// The top square is sized to full available width (capped at 400 for
/// huge phones). The bottom square fits inside the rectangle of
/// remaining vertical space — its side is the smaller of (top-square
/// width, vertical space between top square and controls) — and centers
/// horizontally. Both squares counter-rotate together by `rotation` so
/// content reads upright in position-study mode; both being square
/// keeps the rotated bounding boxes invariant under 90° rotation.
struct SquareScreenLayout<SmallContent: View, BigContent: View, Controls: View>: View {
    var rotation: Double = 0
    /// When false (default), the small (flexible) square is on top and the
    /// big (fixed) square is on the bottom — used by the Idle screen so
    /// the wheel is near the title and tips are anchored above the
    /// button. When true, the order flips: the big square is on top and
    /// the small square is on the bottom — used by Monitoring / Recording /
    /// Analyzing so the spectrogram (complex visualization) gets the
    /// fixed footprint and the short instructional bullets get the
    /// flexible-space slot at the bottom.
    var bigOnTop: Bool = false
    /// Vertical budget reserved for the controls area at the bottom.
    /// RecordingScreen has a single Cancel button (70 fits comfortably);
    /// IdleScreen has a primary action button plus a secondary row, so it
    /// passes a larger value. Squares grow to fill whatever vertical
    /// remains after title + controls.
    var controlsHeight: CGFloat = 70
    @ViewBuilder var smallSquare: SmallContent
    @ViewBuilder var bigSquare: BigContent
    @ViewBuilder var controls: Controls

    var body: some View {
        GeometryReader { outer in
            // Top square: width-limited (capped at 400).
            // Bottom square: largest square fitting into the rectangle
            //   that remains after title (60) + top square + controls.
            // max(0, ...) on every dimension guards the initial layout
            // pass where outer.size is still zero (otherwise SwiftUI logs
            // "Invalid frame dimension").
            let bigSide = max(0, min(outer.size.width - 16, 400))
            let smallAvailable = max(0, outer.size.height - 60 - bigSide - controlsHeight)
            let smallSide = min(bigSide, smallAvailable)
            VStack(spacing: 0) {
                Text("WatchBeat")
                    .font(.largeTitle.bold())
                    .padding(.top, 12)

                if bigOnTop {
                    squareSlot(side: bigSide) { bigSquare }
                    squareSlot(side: smallSide) { smallSquare }
                } else {
                    squareSlot(side: smallSide) { smallSquare }
                    squareSlot(side: bigSide) { bigSquare }
                }

                // Bottom controls — never rotates. Height is per-screen
                // (see controlsHeight).
                controls
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                    .frame(height: controlsHeight)
            }
        }
    }

    /// Fixed-size square slot. Content fills `side × side` and rotates
    /// as a unit; the outer `maxWidth: .infinity` centers it horizontally
    /// inside the parent VStack column.
    private func squareSlot<C: View>(side: CGFloat, @ViewBuilder content: () -> C) -> some View {
        content()
            .frame(width: side, height: side)
            .rotationEffect(.degrees(rotation))
            .animation(.easeInOut(duration: 0.28), value: rotation)
            .frame(maxWidth: .infinity)
    }
}
