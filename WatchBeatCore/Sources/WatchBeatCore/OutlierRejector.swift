import Foundation

/// Per-class quadratic-MAD outlier rejection used by the Reference picker.
///
/// A single bad pick (noise event in the gap, wrong sub-event) can blow
/// out the linear regression: outlier shifts slope, residuals carry an
/// unmodeled trend, and dots visibly diverge from the fitted line on the
/// timegraph (see OddRegression.wav, where one tock at +97 ms dragged the
/// slope by ~43 s/day).
///
/// We fit a quadratic per class — flexible enough to absorb genuine rate
/// wandering — and use it ONLY as a reference line for residuals. Drop
/// any beat whose residual from the quadratic exceeds 3 × 1.4826 × MAD
/// (robust 3σ), floored at 5 ms so a pathologically tight watch doesn't
/// have its real jitter clipped. Iterate the fit-detect-drop cycle:
/// after dropping the worst, fit a new quadratic on the survivors but
/// evaluate residuals against the ORIGINAL indices — points dropped on
/// iter 1 can be re-included on iter 2 if the better quadratic shows
/// they were fine. Converges in 2-3 passes.
struct OutlierRejector {
    /// Beat positions in seconds, indexed by beatIndex. The rejector
    /// reads from this for the quadratic fit; passing it once at init
    /// avoids re-passing on every clean() call.
    let beatPositions: [Double]

    /// Drop outliers from the given beat indices. Returns the surviving
    /// indices (a subset of the input). Indices below the input's count
    /// are returned as-is (we need at least 8 points to attempt a
    /// quadratic fit).
    func clean(_ idxs: [Int]) -> [Int] {
        guard idxs.count >= 8 else { return idxs }
        var kept = idxs
        for _ in 0..<5 {
            guard let (a, b, c) = fitQuadratic(kept) else { return kept }
            var residuals: [Double] = []; residuals.reserveCapacity(idxs.count)
            for i in idxs {
                let x = Double(i)
                residuals.append(beatPositions[i] - (a + b * x + c * x * x))
            }
            let sortedR = residuals.sorted()
            let medianR = sortedR[sortedR.count / 2]
            let absDev = residuals.map { abs($0 - medianR) }.sorted()
            let mad = absDev[absDev.count / 2]
            let threshold = max(3.0 * 1.4826 * mad, 0.005)  // 5 ms floor
            var nextKept: [Int] = []; nextKept.reserveCapacity(idxs.count)
            for (k, i) in idxs.enumerated() where abs(residuals[k] - medianR) <= threshold {
                nextKept.append(i)
            }
            if nextKept == kept { return kept }
            kept = nextKept
        }
        return kept
    }

    /// Fit y = a + b·x + c·x² to (beatIndex, beatPosition) for the given
    /// indices. Returns (a, b, c) or nil if the system is singular.
    private func fitQuadratic(_ idxs: [Int]) -> (Double, Double, Double)? {
        guard idxs.count >= 4 else { return nil }
        let n = Double(idxs.count)
        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var sy = 0.0, sxy = 0.0, sx2y = 0.0
        for i in idxs {
            let x = Double(i); let y = beatPositions[i]
            let x2 = x * x
            s1 += x; s2 += x2; s3 += x2 * x; s4 += x2 * x2
            sy += y; sxy += x * y; sx2y += x2 * y
        }
        let det =
            n * (s2 * s4 - s3 * s3)
          - s1 * (s1 * s4 - s3 * s2)
          + s2 * (s1 * s3 - s2 * s2)
        guard abs(det) > 1e-30 else { return nil }
        let detA =
            sy * (s2 * s4 - s3 * s3)
          - s1 * (sxy * s4 - s3 * sx2y)
          + s2 * (sxy * s3 - s2 * sx2y)
        let detB =
            n * (sxy * s4 - s3 * sx2y)
          - sy * (s1 * s4 - s3 * s2)
          + s2 * (s1 * sx2y - sxy * s2)
        let detC =
            n * (s2 * sx2y - sxy * s3)
          - s1 * (s1 * sx2y - sxy * s2)
          + sy * (s1 * s3 - s2 * s2)
        return (detA / det, detB / det, detC / det)
    }
}
