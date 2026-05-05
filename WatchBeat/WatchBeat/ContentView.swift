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
            case .quartzDetected:
                QuartzDetectedScreen(coordinator: coordinator)
            case .micUnavailable(let diagnostic):
                MicUnavailableScreen(diagnostic: diagnostic, coordinator: coordinator)
            }
        }
        // iOS-style edge-pan swipe-right "back" gesture. Triggers when the
        // user starts a drag near the left edge (within 30 pt) and drags
        // rightward at least 80 pt without much vertical wander. Routing:
        //   - monitoring / recording / result: → idle (start fresh)
        //   - all failure screens: → monitoring (back to listen)
        //   - idle / analyzing: no-op
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let startedAtEdge = value.startLocation.x < 30
                    let movedRight = value.translation.width > 80
                    let mostlyHorizontal = abs(value.translation.height) < abs(value.translation.width)
                    guard startedAtEdge && movedRight && mostlyHorizontal else { return }
                    handleSwipeBack()
                }
        )
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                coordinator.handleBackgrounded()
            }
        }
    }

    private func handleSwipeBack() {
        switch coordinator.state {
        case .monitoring, .recording:
            coordinator.cancelMeasurement()
        case .result:
            coordinator.cancelMeasurement()  // returns to .idle
        case .needsService, .rateConfusion, .weakSignal,
             .lowAnalyticalConfidence, .quartzDetected, .micUnavailable:
            coordinator.startMonitoring()
        case .idle, .analyzing:
            break
        }
    }
}

#Preview {
    ContentView()
}
