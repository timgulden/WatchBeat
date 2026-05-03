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

// MARK: - Bottom Row

/// Persistent grip reminder pinned to the bottom-left of the controls
/// area, and (on Listening/Measuring) a centered Cancel button overlaid on
/// the same row. Fixed height so the primary action button above it lands
/// in the same vertical position on Idle, Listening, and Measuring.
struct BottomRow: View {
    var cancelAction: (() -> Void)? = nil

    var body: some View {
        ZStack {
            HStack {
                Text("← CROWN LEFT")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)
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
