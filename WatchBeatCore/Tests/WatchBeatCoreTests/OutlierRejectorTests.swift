import XCTest
@testable import WatchBeatCore

/// Tests for the per-class quadratic-MAD outlier rejection used by the
/// Reference picker. The rejector takes a position array and a list of
/// indices into it; clean(idxs:) returns the subset that survives the
/// 3 × 1.4826 × MAD threshold (floored at 5 ms).
final class OutlierRejectorTests: XCTestCase {

    /// 12 evenly-spaced positions, one shifted +97 ms (the OddRegression
    /// case). The single outlier should be dropped; everything else
    /// kept, even though the quadratic fit is initially distorted by it.
    func test_singleHugeOutlier_dropsOnlyTheOutlier() {
        // Period 0.2 s; positions in seconds, beat indices 0...11.
        var positions = (0..<12).map { Double($0) * 0.2 }
        positions[5] += 0.097  // single +97 ms outlier
        let rejector = OutlierRejector(beatPositions: positions)
        let kept = rejector.clean(Array(0..<12))
        XCTAssertEqual(kept, [0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11])
    }

    /// Clean evenly-spaced positions with no outliers — every input
    /// index should survive.
    func test_allClean_keepsEverything() {
        let positions = (0..<12).map { Double($0) * 0.2 }
        let rejector = OutlierRejector(beatPositions: positions)
        let kept = rejector.clean(Array(0..<12))
        XCTAssertEqual(kept, Array(0..<12))
    }

    /// Slowly-wandering positions (quadratic curve) — the quadratic fit
    /// should absorb the wandering and treat all points as in-line.
    /// This is why we use a quadratic instead of a linear baseline:
    /// genuine rate drift shouldn't masquerade as outliers.
    func test_quadraticWandering_keepsEverything() {
        // y = 0.2*x + 0.0001*x² — a real watch slowly speeding up.
        let positions = (0..<20).map { i -> Double in
            let x = Double(i)
            return 0.2 * x + 0.0001 * x * x
        }
        let rejector = OutlierRejector(beatPositions: positions)
        let kept = rejector.clean(Array(0..<20))
        XCTAssertEqual(kept, Array(0..<20))
    }

    /// Below the minimum count (8) the rejector returns the input as-is
    /// without attempting a fit.
    func test_belowMinimumCount_returnsInputAsIs() {
        let positions = (0..<12).map { Double($0) * 0.2 }
        let rejector = OutlierRejector(beatPositions: positions)
        let kept = rejector.clean([0, 1, 2, 3, 4, 5])  // only 6 < 8 minimum
        XCTAssertEqual(kept, [0, 1, 2, 3, 4, 5])
    }

    /// Multiple outliers — both should be dropped via iteration. The
    /// fit-detect-drop loop converges within a few passes; outliers
    /// dropped early stop biasing the quadratic so subsequent iterations
    /// see the cleaner shape.
    func test_multipleOutliers_dropsAll() {
        var positions = (0..<16).map { Double($0) * 0.2 }
        positions[3] += 0.05   // +50 ms
        positions[10] -= 0.04  // -40 ms
        let rejector = OutlierRejector(beatPositions: positions)
        let kept = rejector.clean(Array(0..<16))
        XCTAssertFalse(kept.contains(3))
        XCTAssertFalse(kept.contains(10))
        XCTAssertEqual(kept.count, 14)
    }

    /// Tight scatter that doesn't exceed the 5 ms floor — nothing
    /// dropped even though MAD is small. Floor protects pathologically
    /// tight watches from having their real jitter clipped.
    func test_tightJitterUnderFloor_keepsEverything() {
        // ±2 ms jitter around a perfectly linear ramp.
        var positions = (0..<12).map { Double($0) * 0.2 }
        for i in 0..<positions.count {
            positions[i] += (i % 2 == 0 ? 0.002 : -0.002)
        }
        let rejector = OutlierRejector(beatPositions: positions)
        let kept = rejector.clean(Array(0..<12))
        XCTAssertEqual(kept, Array(0..<12))
    }
}
