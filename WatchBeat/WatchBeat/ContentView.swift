import SwiftUI

/// Top-level state switch. Each `State` case routes to its own dedicated
/// screen file. Phase 2 of ARCHITECTURE_REMEDIATION.md split the previous
/// 1000-line ContentView into one file per screen plus shared building
/// blocks (SquareScreenLayout, WatchLogo, SharedComponents).
struct ContentView: View {
    @StateObject private var coordinator = MeasurementCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch coordinator.state {
            case .idle:
                IdleScreen(coordinator: coordinator)
            case .monitoring:
                MonitoringScreen(coordinator: coordinator)
            case .recording:
                RecordingScreen(coordinator: coordinator)
            case .analyzing:
                AnalyzingScreen()
            case .result(let data):
                ResultScreen(data: data, coordinator: coordinator)
            case .needsService(let data):
                NeedsServiceScreen(data: data, coordinator: coordinator)
            case .rateConfusion(let data):
                RateConfusionScreen(data: data, coordinator: coordinator)
            case .weakSignal(let diagnostic):
                WeakSignalScreen(diagnostic: diagnostic, coordinator: coordinator)
            case .lowAnalyticalConfidence:
                LowAnalyticalConfidenceScreen(coordinator: coordinator)
            case .micUnavailable(let diagnostic):
                MicUnavailableScreen(diagnostic: diagnostic, coordinator: coordinator)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                coordinator.handleBackgrounded()
            }
        }
    }
}

#Preview {
    ContentView()
}
