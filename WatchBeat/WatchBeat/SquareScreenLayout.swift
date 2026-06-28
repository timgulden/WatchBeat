import SwiftUI

/// Two-square layout used by idle, listening, and measuring screens.
///
/// The bottom content is a near-screen-width square (graph + caption); the
/// top content is a smaller square (wheel + 12-o'clock marker) that centers
/// in the remaining space above it. Both squares counter-rotate together by
/// `rotation` so the content reads upright regardless of phone pose —
/// squares are chosen so their bounding boxes are invariant under 90°
/// rotation. The title and bottom controls never rotate.
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
    @ViewBuilder var smallSquare: SmallContent
    @ViewBuilder var bigSquare: BigContent
    @ViewBuilder var controls: Controls

    var body: some View {
        GeometryReader { outer in
            // max(0, ...) guards the initial layout pass where outer.size is
            // still zero — without it, .frame() gets a negative side and
            // SwiftUI logs "Invalid frame dimension".
            let bigSide = max(0, min(outer.size.width - 16, 400))
            VStack(spacing: 0) {
                Text("WatchBeat")
                    .font(.largeTitle.bold())
                    .padding(.top, 12)

                if bigOnTop {
                    bigSquareView(bigSide: bigSide)
                    smallSquareView
                } else {
                    smallSquareView
                    bigSquareView(bigSide: bigSide)
                }

                // Bottom controls — fixed height, never rotates.
                controls
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                    .frame(height: 110)
            }
        }
    }

    /// Flexible-space slot. Caller's content is expected to be square-
    /// shaped (e.g., via .aspectRatio(1, contentMode: .fit)) so the
    /// rotation effect is invariant under 90°.
    private var smallSquareView: some View {
        smallSquare
            .rotationEffect(.degrees(rotation))
            .animation(.easeInOut(duration: 0.28), value: rotation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Fixed-size square slot. Caller's content fills the square.
    private func bigSquareView(bigSide: CGFloat) -> some View {
        bigSquare
            .frame(width: bigSide, height: bigSide)
            .rotationEffect(.degrees(rotation))
            .animation(.easeInOut(duration: 0.28), value: rotation)
            .frame(maxWidth: .infinity)
    }
}
