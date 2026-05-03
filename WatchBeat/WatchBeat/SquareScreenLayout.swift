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

                // Small square area — fills remaining vertical space between
                // title and big square, with the square content centered.
                smallSquare
                    .rotationEffect(.degrees(rotation))
                    .animation(.easeInOut(duration: 0.28), value: rotation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Big square — fixed square footprint, centered horizontally.
                bigSquare
                    .frame(width: bigSide, height: bigSide)
                    .rotationEffect(.degrees(rotation))
                    .animation(.easeInOut(duration: 0.28), value: rotation)
                    .frame(maxWidth: .infinity)

                // Bottom controls — fixed height, never rotates.
                controls
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                    .frame(height: 110)
            }
        }
    }
}
