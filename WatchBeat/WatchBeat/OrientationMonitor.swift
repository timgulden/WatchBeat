import CoreMotion
import Foundation

/// Streams 10 Hz device-gravity samples from CoreMotion, classifies each
/// into a WatchPosition, and maintains a short rolling history so the
/// coordinator can check whether the position held constant over a given
/// time window.
@MainActor
final class OrientationMonitor {

    /// Latest classification, updated whenever a new gravity sample arrives.
    /// Nil when the phone is between positions (tilted).
    private(set) var currentPosition: WatchPosition?

    /// Called every time `currentPosition` changes (including nil transitions).
    /// Runs on the main actor.
    var onPositionChange: ((WatchPosition?) -> Void)?

    /// Closest-axis classification with no alignment threshold. Snaps at
    /// 45° tilt boundaries — used to drive UI counter-rotation so the screen
    /// flips to landscape as soon as the phone tips past 45°, even when the
    /// stricter `currentPosition` is still nil.
    private(set) var closestPosition: WatchPosition = .dialDown

    /// Called every time `closestPosition` changes.
    var onClosestPositionChange: ((WatchPosition) -> Void)?

    private let motionManager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "OrientationMonitor"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    /// (timestamp, classified position) samples. Nil entries represent
    /// transitional frames (gravity didn't align with any axis clearly).
    private var history: [(time: ContinuousClock.Instant, position: WatchPosition?)] = []
    /// Keep enough history to cover the 15 s analysis window plus slack.
    private let historyWindow: Double = 20.0

    init() {
        motionManager.deviceMotionUpdateInterval = 0.1
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable,
              !motionManager.isDeviceMotionActive else { return }
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let motion else { return }
            let g = motion.gravity
            let pos = WatchPosition.classify(gx: g.x, gy: g.y, gz: g.z)
            let closest = WatchPosition.closest(gx: g.x, gy: g.y, gz: g.z)
            Task { @MainActor [weak self] in
                self?.record(position: pos, closest: closest)
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        history.removeAll()
        let old = currentPosition
        currentPosition = nil
        if old != nil { onPositionChange?(nil) }
    }

    private func record(position: WatchPosition?, closest: WatchPosition) {
        let now = ContinuousClock.now
        history.append((now, position))

        let cutoff = now - .seconds(historyWindow)
        while let first = history.first, first.time < cutoff {
            history.removeFirst()
        }

        if position != currentPosition {
            currentPosition = position
            onPositionChange?(position)
        }

        if closest != closestPosition {
            closestPosition = closest
            onClosestPositionChange?(closest)
        }
    }

    /// Returns the unique position held across the entire window
    /// `[endTime − duration, endTime]`, or nil if the position changed (or
    /// ever dropped to nil) during that window. Also returns nil if we have
    /// no samples covering the window.
    func position(endingAt endTime: ContinuousClock.Instant, duration: Double) -> WatchPosition? {
        let startTime = endTime - .seconds(duration)
        let window = history.filter { $0.time >= startTime && $0.time <= endTime }
        guard window.count >= 2 else { return nil }
        guard let first = window.first?.position else { return nil }
        for sample in window where sample.position != first {
            return nil
        }
        return first
    }
}
