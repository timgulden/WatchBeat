import Foundation

// Pure utility functions used by both the production and Reference
// pickers. Top-level functions in the WatchBeatCore module (no class/
// struct membership needed). They have no state and depend only on
// their inputs, so they live outside MeasurementPipeline rather than
// as methods on it.

/// Box-car moving average over `x` with the window centered on each
/// sample. Edge samples use whatever portion of the window fits within
/// the array. Returns an array the same length as `x`.
func movingAverage(of x: [Float], windowSamples: Int) -> [Float] {
    let n = x.count
    guard windowSamples > 1, n > 0 else { return x }
    let half = windowSamples / 2
    var out = [Float](repeating: 0, count: n)
    var runSum: Float = 0
    var left = 0
    var right = -1
    while right + 1 <= min(n - 1, half) {
        right += 1
        runSum += x[right]
    }
    for i in 0..<n {
        let width = right - left + 1
        out[i] = width > 0 ? runSum / Float(width) : 0
        let nextRight = min(n - 1, i + 1 + half)
        while right < nextRight {
            right += 1
            runSum += x[right]
        }
        let nextLeft = max(0, i + 1 - half)
        while left < nextLeft {
            runSum -= x[left]
            left += 1
        }
    }
    return out
}

/// Median of an Int array, naively via sort. Returns 0 for empty.
/// (We don't need quickselect — these arrays are small.)
func sortedMedianInt(_ values: [Int]) -> Int {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

/// Median of a Float array, naively via sort. Returns 0 for empty.
func sortedMedian(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

/// Smallest power of two ≥ `n`. Used to size FFT inputs.
func nextPowerOfTwo(_ n: Int) -> Int {
    var v = n - 1
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16
    return v + 1
}
