import Foundation

/// One of the six standard watchmaking positions, inferred from device
/// orientation under the assumption that the watch caseback is pressed
/// against the phone's **bottom edge** (the short edge opposite the speaker)
/// with the crown pointing toward the phone's left side (−X in device frame).
///
/// Axis mapping (phone device frame → watch feature):
///   +X → 9-o'clock side of the dial
///   −X → crown (3-o'clock)
///   +Y → caseback (into the phone's bottom edge)
///   −Y → dial face (away from the phone, past its bottom edge)
///   +Z → 6-o'clock
///   −Z → 12-o'clock
///
/// Sanity-check poses (gravity in device frame → watch position):
///   portrait upright          (0, −1, 0) → Dial Down
///   portrait upside-down      (0, +1, 0) → Dial Up
///   flat, screen up           (0, 0, −1) → 6 Up
///   flat, screen down         (0, 0, +1) → 12 Up
///   landscape, right-side up  (−1, 0, 0) → 9 Up
///   landscape, left-side up   (+1, 0, 0) → 3 Up (crown up)
/// Labels follow the six-position timing convention used by watchmakers and
/// commercial timing machines (Witschi, Greiner, etc.): DU/DD for flat;
/// CU/CD for the crown-at-top / crown-at-bottom verticals; and 12U/6U (a.k.a.
/// PU/PD, pendant up/down) for the two remaining vertical positions.
enum WatchPosition: String, CaseIterable, Sendable {
    case dialUp      // DU
    case dialDown    // DD
    case crownUp     // CU — crown (3-o'clock) at top
    case crownDown   // CD — crown at bottom (9-o'clock at top)
    case twelveUp    // 12U / PU — 12-o'clock at top
    case sixUp       // 6U  / PD — 6-o'clock at top

    /// Vertical positions are named by which dial numeral points up ("3 Up"
    /// rather than "Crown Up") — unambiguous for users who don't know
    /// crown-side terminology.
    var displayName: String {
        switch self {
        case .dialUp:     return "Dial Up"
        case .dialDown:   return "Dial Down"
        case .crownUp:    return "3 Up"
        case .crownDown:  return "9 Up"
        case .twelveUp:   return "12 Up"
        case .sixUp:      return "6 Up"
        }
    }

    /// Compact code used in saved-recording filenames.
    var shortCode: String {
        switch self {
        case .dialUp:     return "DU"
        case .dialDown:   return "DD"
        case .crownUp:    return "3U"
        case .crownDown:  return "9U"
        case .twelveUp:   return "12U"
        case .sixUp:      return "6U"
        }
    }

    /// How to hold the *phone* to put the watch in this position, given the
    /// study grip (caseback on the phone's bottom edge, crown left). Phone-
    /// centric wording because the user reasons about the thing in their
    /// hand, not the watch's frame of reference.
    var phonePoseInstruction: String {
        switch self {
        case .dialUp:     return "Hold the phone vertical, upside down — watch above the phone."
        case .dialDown:   return "Hold the phone vertical, upright — watch below the phone."
        case .sixUp:      return "Lay the phone flat on its back, screen up."
        case .twelveUp:   return "Lay the phone flat, screen down."
        case .crownUp:    return "Turn the phone on its side — left edge (volume buttons) up."
        case .crownDown:  return "Turn the phone on its side — right edge (side button) up."
        }
    }

    /// Classify a device-frame gravity vector (iOS CoreMotion convention —
    /// points in the direction gravity pulls, magnitude ≈ 1 g). Returns nil
    /// unless gravity is within ±10° of a single device axis (dominant
    /// component ≥ cos 10° ≈ 0.9848 g). Strict alignment matters because
    /// positional rate differences between watch positions can be small;
    /// misreporting a position would mislead the user.
    static func classify(gx: Double, gy: Double, gz: Double) -> WatchPosition? {
        let ax = abs(gx), ay = abs(gy), az = abs(gz)
        let m = max(ax, ay, az)
        guard m >= 0.9848 else { return nil }
        return axisWinner(ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz)
    }

    /// Closest-axis classifier with no alignment threshold — always returns
    /// a value. Used for UI counter-rotation decisions where "which way is
    /// up" should snap at 45° tilt boundaries, decoupled from the stricter
    /// label classifier above.
    static func closest(gx: Double, gy: Double, gz: Double) -> WatchPosition {
        let ax = abs(gx), ay = abs(gy), az = abs(gz)
        return axisWinner(ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz)
    }

    private static func axisWinner(ax: Double, ay: Double, az: Double,
                                   gx: Double, gy: Double, gz: Double) -> WatchPosition {
        let m = max(ax, ay, az)
        // X axis: gravity toward −X means the crown (watch 3) points down
        // in world → watch 9 is up (crown down). Opposite: crown up.
        if ax == m { return gx < 0 ? .crownDown : .crownUp }
        // Y axis: gravity toward −Y means the dial (on the −Y side of the
        // phone) is down in world → dial down. Opposite: dial up.
        if ay == m { return gy < 0 ? .dialDown : .dialUp }
        // Z axis: gravity toward −Z means watch 12 (the −Z side) is down →
        // 6 is up. Opposite: 12 is up.
        return gz < 0 ? .sixUp : .twelveUp
    }
}
