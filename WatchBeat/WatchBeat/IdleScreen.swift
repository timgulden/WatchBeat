import SwiftUI

struct IdleScreen: View {
    @ObservedObject var coordinator: MeasurementCoordinator
    @AppStorage("positionStudyEnabled") private var positionStudyEnabled: Bool = false

    var body: some View {
        SquareScreenLayout {
            WatchLogo()
        } bigSquare: {
            // Updated post-multiband / post-template-matching: placement
            // is much more forgiving than the old algorithm needed it to
            // be. Tips focus on what genuinely helps (steady contact,
            // quiet room) rather than fussy positioning advice.
            VStack(alignment: .leading, spacing: 14) {
                tipRow(icon: "waveform", text: "Hold the mic on the bottom of the phone against your watch.")
                tipRow(icon: "applewatch", text: "On-wrist works as well as on a bench.")
                tipRow(icon: "hand.raised", text: "Hold steady once you press Listen.")
                tipRow(icon: "ear", text: "A quieter environment is best.")
                tipRow(icon: "rotate.3d", text: "Turn on POSITION STUDY for a full positional analysis.")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        } controls: {
            VStack(spacing: 10) {
                ActionButton(title: "Listen") {
                    coordinator.startMonitoring()
                }
                BottomRow {
                    Button {
                        positionStudyEnabled.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: positionStudyEnabled
                                  ? "checkmark.square.fill"
                                  : "square")
                                .font(.footnote)
                            Text("POSITION STUDY")
                                .font(.footnote.weight(.bold))
                        }
                        .foregroundStyle(positionStudyEnabled ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Position Study mode")
                    .accessibilityValue(positionStudyEnabled ? "on" : "off")
                }
            }
        }
    }
}
