import Foundation
import Accelerate
import WatchBeatCore

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// Use the best sample: q80
let filename = "watchbeat_20260414_094252_21600bph_q80.wav"
let url = URL(fileURLWithPath: dir).appendingPathComponent(filename)
let buffer = try WAVReader.read(url: url)
let raw = buffer.samples
let sr = buffer.sampleRate
let n = raw.count

print("=== Tick Shape Analysis: \(filename) ===")
print("Samples: \(n), Rate: \(sr) Hz, Duration: \(Double(n)/sr)s")
print()

// Step 1: Find tick positions using the pipeline's approach
let periodSamples = Int(round(sr / 6.0))  // 21600 bph = 6 Hz
print("Period: \(periodSamples) samples (\(String(format: "%.1f", 1000.0 * Double(periodSamples)/sr))ms)")

// Squared signal
var squared = [Float](repeating: 0, count: n)
vDSP_vsq(raw, 1, &squared, 1, vDSP_Length(n))

// Find tick positions using median alignment (same as pipeline)
let numWindows = n / periodSamples
var peakOffsets = [Int]()
for w in 0..<numWindows {
    let wStart = w * periodSamples
    var bestIdx = 0
    var bestVal: Float = 0
    for i in 0..<periodSamples {
        if squared[wStart + i] > bestVal { bestVal = squared[wStart + i]; bestIdx = i }
    }
    peakOffsets.append(bestIdx)
}
let medianOffset = peakOffsets.sorted()[peakOffsets.count / 2]
print("Median tick offset: \(medianOffset) samples (\(String(format: "%.2f", 1000.0 * Double(medianOffset)/sr))ms into period)")

// Step 2: Stack (average) ticks centered on their peaks
// Use a window of ±4ms around each tick center (captures the full tick burst)
let stackHalfWidth = Int(sr * 0.004)  // 4ms = 192 samples at 48kHz
let stackWidth = 2 * stackHalfWidth + 1
print("Stack window: ±\(stackHalfWidth) samples (±\(String(format: "%.1f", 1000.0 * Double(stackHalfWidth)/sr))ms)")
print()

var stackedRaw = [Double](repeating: 0, count: stackWidth)
var stackedSquared = [Double](repeating: 0, count: stackWidth)
var tickCount = 0

// Also collect individual tick peak energies for confirmation
var tickEnergies = [Float]()
var gapEnergies = [Float]()

let tickWindow = max(10, periodSamples / 5)  // 20% window for confirmation
let halfTick = tickWindow / 2

for w in 0..<numWindows {
    let center = w * periodSamples + medianOffset
    guard center >= stackHalfWidth && center + stackHalfWidth < n else { continue }

    // Check if this is a real tick (energy above gap)
    let wStart = center - halfTick
    var tickE: Float = 0
    for i in 0..<tickWindow { tickE += squared[wStart + i] }
    tickEnergies.append(tickE)

    let gapCenter = center + periodSamples / 2
    if gapCenter >= halfTick && gapCenter + halfTick < n {
        var gapE: Float = 0
        let gStart = gapCenter - halfTick
        for i in 0..<tickWindow { gapE += squared[gStart + i] }
        gapEnergies.append(gapE)
    }
}

let medianGap = gapEnergies.sorted()[gapEnergies.count / 2]
let threshold = medianGap * 2.0

// Now stack only confirmed ticks
var confirmedCount = 0
for w in 0..<numWindows {
    let center = w * periodSamples + medianOffset
    guard center >= stackHalfWidth && center + stackHalfWidth < n else { continue }
    guard w < tickEnergies.count && tickEnergies[w] > threshold else { continue }

    // Fine-align: find the actual peak within ±20 samples of the median position
    var bestOff = 0
    var bestVal: Float = 0
    let searchR = 20
    for d in -searchR...searchR {
        let idx = center + d
        if idx >= 0 && idx < n && squared[idx] > bestVal { bestVal = squared[idx]; bestOff = d }
    }
    let alignedCenter = center + bestOff

    guard alignedCenter >= stackHalfWidth && alignedCenter + stackHalfWidth < n else { continue }

    for i in 0..<stackWidth {
        stackedRaw[i] += Double(raw[alignedCenter - stackHalfWidth + i])
        stackedSquared[i] += Double(squared[alignedCenter - stackHalfWidth + i])
    }
    confirmedCount += 1
}

guard confirmedCount > 0 else {
    print("No confirmed ticks to stack!")
    exit(1)
}

// Average
for i in 0..<stackWidth {
    stackedRaw[i] /= Double(confirmedCount)
    stackedSquared[i] /= Double(confirmedCount)
}

print("Stacked \(confirmedCount) confirmed ticks")
print()

// Step 3: Print the stacked tick shape
// Show the envelope (abs of averaged raw signal) and the energy (averaged squared)
print("=== Stacked Tick Shape (energy) ===")
print("Time(ms)  Energy        |  Waveform")

let peakEnergy = stackedSquared.max() ?? 1
let peakRaw = stackedRaw.map { abs($0) }.max() ?? 1

// Print at 0.1ms resolution (every ~5 samples at 48kHz)
let step = max(1, Int(sr * 0.0001))  // 0.1ms steps
for i in stride(from: 0, to: stackWidth, by: step) {
    let timeMs = Double(i - stackHalfWidth) / sr * 1000.0
    let energy = stackedSquared[i]
    let rawVal = stackedRaw[i]

    // Bar chart of energy
    let barLen = Int(energy / peakEnergy * 50)
    let bar = String(repeating: "#", count: barLen)

    // Only print near the tick (±3ms)
    if abs(timeMs) <= 3.0 {
        print(String(format: "%+6.2fms  %.2e  %@", timeMs, energy, bar))
    }
}

print()

// Step 4: Measure tick characteristics
// Find the -6dB points (where energy drops to 25% of peak)
let peakIdx = stackedSquared.firstIndex(of: peakEnergy) ?? stackHalfWidth
let threshold6dB = peakEnergy * 0.25

// Search left for -6dB point
var leftIdx = peakIdx
while leftIdx > 0 && stackedSquared[leftIdx] > threshold6dB { leftIdx -= 1 }

// Search right for -6dB point
var rightIdx = peakIdx
while rightIdx < stackWidth - 1 && stackedSquared[rightIdx] > threshold6dB { rightIdx += 1 }

let tickWidthSamples = rightIdx - leftIdx
let tickWidthMs = Double(tickWidthSamples) / sr * 1000.0

print("=== Tick Measurements ===")
print("Peak at: \(String(format: "%+.2f", Double(peakIdx - stackHalfWidth) / sr * 1000.0))ms")
print("Tick width (-6dB): \(String(format: "%.2f", tickWidthMs))ms (\(tickWidthSamples) samples)")
print("Peak energy: \(String(format: "%.2e", peakEnergy))")
print("SNR (peak/baseline): \(String(format: "%.1f", peakEnergy / (stackedSquared.first ?? 1e-20)))")

// Check for sub-events: look for multiple peaks in the energy
print()
print("=== Sub-event Search ===")
// Smooth the stacked energy with a short window to find distinct peaks
let smoothW = Int(sr * 0.0003) // 0.3ms smoothing
var smoothed = [Double](repeating: 0, count: stackWidth)
for i in smoothW..<(stackWidth - smoothW) {
    var sum = 0.0
    for j in (i-smoothW)...(i+smoothW) { sum += stackedSquared[j] }
    smoothed[i] = sum / Double(2 * smoothW + 1)
}

// Find local maxima in the smoothed energy within ±3ms of center
var peaks: [(idx: Int, value: Double)] = []
let searchRange = Int(sr * 0.003)  // ±3ms
let minPeakHeight = peakEnergy * 0.1  // at least 10% of main peak

for i in (stackHalfWidth - searchRange + 1)..<(stackHalfWidth + searchRange - 1) {
    if smoothed[i] > smoothed[i-1] && smoothed[i] > smoothed[i+1] && smoothed[i] > minPeakHeight {
        // Check it's a real local max (not just noise)
        let isLocalMax = smoothed[i] >= smoothed[max(0, i-3)] && smoothed[i] >= smoothed[min(stackWidth-1, i+3)]
        if isLocalMax {
            peaks.append((i, smoothed[i]))
        }
    }
}

// Merge nearby peaks (within 0.3ms)
var mergedPeaks: [(idx: Int, value: Double)] = []
for peak in peaks.sorted(by: { $0.value > $1.value }) {
    let tooClose = mergedPeaks.contains { abs($0.idx - peak.idx) < Int(sr * 0.0003) }
    if !tooClose { mergedPeaks.append(peak) }
}
mergedPeaks.sort { $0.idx < $1.idx }

print("Found \(mergedPeaks.count) sub-event peaks:")
for (i, peak) in mergedPeaks.enumerated() {
    let timeMs = Double(peak.idx - stackHalfWidth) / sr * 1000.0
    let relMag = peak.value / peakEnergy * 100
    print("  Peak \(i+1): \(String(format: "%+.2f", timeMs))ms  (\(String(format: "%.0f", relMag))% of max)")
}

if mergedPeaks.count >= 2 {
    let separation = Double(mergedPeaks[1].idx - mergedPeaks[0].idx) / sr * 1000.0
    print("  Separation between first two peaks: \(String(format: "%.2f", separation))ms")
    print("  (This may correspond to unlock-impulse or impulse-drop interval)")
}

print()
