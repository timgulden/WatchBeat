import SwiftUI

/// Between-readings screen of the Position Study: tells the user which
/// position is next and how to hold the phone, shows live "in position"
/// feedback, and auto-starts the recording once the pose has been held
/// briefly — no tap needed. Skip is the only per-position action.
struct StudyPositioningScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator

    private var target: WatchPosition? { coordinator.study?.target }
    private var inPosition: Bool { coordinator.currentPosition == target }

    var body: some View {
        SquareScreenLayout(rotation: coordinator.latchedUIRotation, bigOnTop: true) {
            progressPanel
        } bigSquare: {
            posePanel
        } controls: {
            VStack(spacing: 10) {
                BottomRow(cancelAction: { coordinator.cancelStudy() }) {
                    Button("Skip Position") {
                        coordinator.skipStudyPosition()
                    }
                    .font(.footnote.weight(.bold))
                }
            }
        }
    }

    /// Big square: position name, phone-pose glyph + instruction, live
    /// hold status.
    private var posePanel: some View {
        VStack(spacing: 12) {
            if let study = coordinator.study {
                Text("Position \(study.currentIndex + 1) of \(PositionStudy.positions.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(target?.displayName ?? "")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            poseGlyph
                .frame(height: 70)
            Text(target?.phonePoseInstruction ?? "")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            holdStatus
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// iPhone symbol rotated to depict the target pose. Flat poses tilt
    /// via a 3D rotation so "lay it down" reads visually.
    private var poseGlyph: some View {
        Image(systemName: "iphone")
            .font(.system(size: 56, weight: .light))
            .foregroundStyle(inPosition ? Color.green : Color.secondary)
            .rotationEffect(.degrees(glyphRotation))
            .rotation3DEffect(.degrees(glyphTilt), axis: (x: 1, y: 0, z: 0))
            .animation(.easeInOut(duration: 0.2), value: inPosition)
            .accessibilityHidden(true)
    }

    private var glyphRotation: Double {
        switch target {
        case .dialUp:    return 180
        case .crownUp:   return 90    // left edge up
        case .crownDown: return -90   // right edge up
        default:         return 0
        }
    }

    private var glyphTilt: Double {
        switch target {
        case .sixUp:    return 55   // flat, screen up
        case .twelveUp: return -55  // flat, screen down
        default:        return 0
        }
    }

    /// "Move into position" ↔ "Hold still" + dwell ring. Fixed height so
    /// the panel doesn't jump between the two states.
    private var holdStatus: some View {
        HStack(spacing: 8) {
            if inPosition {
                ProgressView(value: coordinator.poseHoldProgress)
                    .progressViewStyle(.circular)
                    .tint(.green)
                Text("Hold still — starting…")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "move.3d")
                    .foregroundStyle(.orange)
                Text("Move the phone into position")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }
        }
        .frame(height: 30)
    }

    /// Small square: checklist of the five positions with completion marks.
    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(PositionStudy.positions.enumerated()), id: \.offset) { index, position in
                HStack(spacing: 10) {
                    statusIcon(index: index)
                        .frame(width: 24)
                    Text(position.displayName)
                        .font(.subheadline.weight(index == coordinator.study?.currentIndex ? .bold : .regular))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func statusIcon(index: Int) -> some View {
        let readings = coordinator.study?.readings ?? []
        if index < readings.count {
            switch readings[index].outcome {
            case .measured:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .skipped:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        } else if index == readings.count {
            Image(systemName: "arrow.right.circle.fill").foregroundStyle(.blue)
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}
