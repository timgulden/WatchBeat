import SwiftUI

// MARK: - Action Button

/// Consistent action button used across all screens.
struct ActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
    }
}

// MARK: - Listening Caption

/// Shared caption block for the listening and measuring screens. A bold
/// position label sits above "Listening..." — when no position is
/// unambiguous, the slot stays reserved (rendered with a space) so the
/// line below never shifts. Since this block lives in ScreenLayout's
/// fixed-minHeight text slot, the wheel above it never moves either.
struct ListeningCaption: View {
    /// Line 2: phase name matching the active wedge ("Listening..." /
    /// "Measuring..." / "Analyzing..." / "Refining..."). Defaults to
    /// "Listening..." since that's the only phase the monitoring screen
    /// ever shows.
    var phaseTitle: String = "Listening..."
    /// Line 3: descriptive context for what the app is doing in the
    /// current phase.
    let subtitle: String
    let position: WatchPosition?

    var body: some View {
        VStack(spacing: 6) {
            Text("Position: \(position?.displayName ?? "Undefined")")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text(phaseTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Simple Tips Block

/// Compact instructional bullets used by the lower box of the Listen
/// screen. Fills its parent slot — no internal aspect-ratio constraint.
struct SimpleTipsBlock: View {
    let title: String
    let tips: [(icon: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.bottom, 4)
            ForEach(0..<tips.count, id: \.self) { i in
                tipRow(icon: tips[i].icon, text: tips[i].text)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Bottom Row

/// Bottom-row strip with a centered Cancel button (on Listening/Measuring)
/// and an optional leading view. By default the leading view shows the
/// "← CROWN LEFT" orientation reminder only when Position Study mode is
/// enabled — outside of study mode the orientation cue isn't meaningful
/// since we're not running per-position analysis. Callers can also supply
/// a custom leading view (used by the Idle screen for the Position Study
/// toggle button).
///
/// Fixed height so the primary action button above lands in the same
/// vertical position across all screens.
struct BottomRow<Leading: View>: View {
    var cancelAction: (() -> Void)? = nil
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        ZStack {
            HStack {
                leading()
                Spacer()
            }
            if let cancel = cancelAction {
                Button("Cancel", action: cancel)
                    .foregroundStyle(.red)
            }
        }
        .frame(height: 30)
    }
}

extension BottomRow where Leading == CrownLeftTipOrNothing {
    /// Default initializer: shows the "← CROWN LEFT" tip if and only if
    /// Position Study mode is enabled.
    init(cancelAction: (() -> Void)? = nil) {
        self.cancelAction = cancelAction
        self.leading = { CrownLeftTipOrNothing() }
    }
}

/// Renders "← CROWN LEFT" when Position Study mode is on, nothing
/// otherwise. Used as the default leading content for BottomRow on every
/// screen except Idle.
struct CrownLeftTipOrNothing: View {
    @AppStorage("positionStudyEnabled") private var positionStudyEnabled: Bool = false

    var body: some View {
        if positionStudyEnabled {
            Text("← CROWN LEFT")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Send Debug Button

/// Small unobtrusive button shown on terminal screens (result + failure
/// pages) when a debug recording is available. Opens DebugReportSheet
/// where the user can review what's being sent and trigger the share
/// sheet. Disabled (greyed) if there's no current recording.
struct SendDebugButton: View {
    @ObservedObject var coordinator: MeasurementCoordinator
    @State private var presentingSheet = false

    var body: some View {
        Button {
            presentingSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "envelope")
                    .font(.footnote)
                Text("Send Debug")
                    .font(.footnote.weight(.medium))
            }
        }
        .foregroundStyle(coordinator.debugRecording.currentRecordingURL == nil ? Color.secondary : Color.blue)
        .disabled(coordinator.debugRecording.currentRecordingURL == nil)
        .accessibilityLabel("Send debug recording to developer")
        .sheet(isPresented: $presentingSheet) {
            DebugReportSheet(debugRecording: coordinator.debugRecording)
        }
    }
}

// MARK: - Tip Row

/// Shared tip row used by all failure screens (and the Idle / RateConfusion
/// / NeedsService screens via their own private wrappers, soon to be
/// replaced by direct calls to this).
func tipRow(icon: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Image(systemName: icon)
            .font(.body)
            .foregroundStyle(.blue)
            .frame(width: 24)
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
