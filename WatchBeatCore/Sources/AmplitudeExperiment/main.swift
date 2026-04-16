import Foundation
import Accelerate
import WatchBeatCore

let liftAngle = 52.0
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let pipeline = MeasurementPipeline()
let conditioner = SignalConditioner()

// MARK: - Helpers

func movingAverage(_ signal: [Float], windowSize: Int) -> [Float] {
    let n = signal.count
    guard windowSize > 1 && windowSize < n else { return signal }
    let outCount = n - windowSize + 1
    var result = [Float](repeating: 0, count: outCount)
    var sum: Float = 0
    for i in 0..<windowSize { sum += signal[i] }
    result[0] = sum / Float(windowSize)
    for i in 1..<outCount {
        sum += signal[i + windowSize - 1] - signal[i - 1]
        result[i] = sum / Float(windowSize)
    }
    return result
}

struct FoldResult {
    let tickPulseMs: Double
    let tockPulseMs: Double
    let tickAmp: Double?
    let tockAmp: Double?
    let foldCount: Int
}

func foldAndMeasure(
    signal: [Float], sampleRate: Double,
    tickTimings: [TickTiming], rateError: Double,
    rate: StandardBeatRate, smoothMs: Double, threshFrac: Double
) -> FoldResult? {
    let n = signal.count
    let beatPeriod = rate.nominalPeriodSeconds * (1.0 - rateError / 86400.0)
    let periodSamples = Int(round(beatPeriod * sampleRate))
    guard periodSamples > 100 && periodSamples < n / 3 && tickTimings.count >= 10 else { return nil }

    var rectified = [Float](repeating: 0, count: n)
    vDSP_vabs(signal, 1, &rectified, 1, vDSP_Length(n))

    let posSmoothSamp = max(3, Int(0.001 * sampleRate))
    let posSignal = movingAverage(rectified, windowSize: posSmoothSamp)
    let sN = posSignal.count
    let halfSmooth = posSmoothSamp / 2

    let searchEnd = min(periodSamples * 3, sN)
    var calibPeak = 0
    var calibVal: Float = 0
    for i in 0..<searchEnd {
        if posSignal[i] > calibVal { calibVal = posSignal[i]; calibPeak = i }
    }
    let estimatedBeat = Double(calibPeak) / (beatPeriod * sampleRate)
    let nearestBeat = Int(round(estimatedBeat))
    let sampleOffset = Double(calibPeak) - beatPeriod * sampleRate * Double(nearestBeat)

    let halfPeriod = periodSamples / 2
    let foldLen = periodSamples * 2
    var folded = [Float](repeating: 0, count: foldLen)
    var foldCount = 0

    let evenTimings = tickTimings.filter { $0.isEvenBeat }
    for timing in evenTimings {
        let expected = Int(beatPeriod * sampleRate * Double(timing.beatIndex) + sampleOffset) - halfSmooth
        let lo = max(0, expected - periodSamples / 4)
        let hi = min(sN - 1, expected + periodSamples / 4)
        guard lo < hi else { continue }
        var peakIdx = lo
        var peakVal: Float = posSignal[lo]
        for j in (lo + 1)...hi {
            if posSignal[j] > peakVal { peakVal = posSignal[j]; peakIdx = j }
        }
        let foldStart = peakIdx - halfPeriod
        guard foldStart >= 0 && foldStart + foldLen < n else { continue }
        for i in 0..<foldLen { folded[i] += rectified[foldStart + i] }
        foldCount += 1
    }
    guard foldCount >= 3 else { return nil }
    let div = Float(foldCount)
    for i in 0..<foldLen { folded[i] /= div }

    let foldSmoothSamp = max(3, Int(smoothMs * 0.001 * sampleRate))
    let smoothed = movingAverage(folded, windowSize: foldSmoothSamp)
    let fN = smoothed.count
    guard fN > periodSamples else { return nil }

    func findPeak(_ target: Int, _ range: Int) -> Int? {
        let lo = max(0, target - range)
        let hi = min(fN - 1, target + range)
        guard lo < hi else { return nil }
        var best = lo; var bestVal: Float = smoothed[lo]
        for j in (lo + 1)...hi { if smoothed[j] > bestVal { bestVal = smoothed[j]; best = j } }
        return best
    }

    guard let tickPeak = findPeak(halfPeriod, periodSamples / 3),
          let tockPeak = findPeak(halfPeriod + periodSamples, periodSamples / 3) else { return nil }

    func pulseWidth(_ peakIdx: Int) -> Double {
        let peakVal = smoothed[peakIdx]
        guard peakVal > 0 else { return 0 }
        let thresh = Float(threshFrac) * peakVal
        let lo = max(0, peakIdx - periodSamples / 3)
        let hi = min(fN - 1, peakIdx + periodSamples / 3)
        var lead = peakIdx
        while lead > lo && smoothed[lead] > thresh { lead -= 1 }
        var trail = peakIdx
        while trail < hi && smoothed[trail] > thresh { trail += 1 }
        return Double(trail - lead) / sampleRate
    }

    let beatPeriodVal = beatPeriod
    let tickPulse = pulseWidth(tickPeak)
    let tockPulse = pulseWidth(tockPeak)

    func amp(_ pulse: Double) -> Double? {
        let ratio = pulse / beatPeriodVal
        guard ratio > 0.001 && ratio < 0.25 else { return nil }
        let s = sin(Double.pi * ratio)
        guard s > 1e-10 else { return nil }
        let a = liftAngle / (2.0 * s)
        return (a >= 100 && a <= 400) ? a : nil
    }

    return FoldResult(
        tickPulseMs: tickPulse * 1000, tockPulseMs: tockPulse * 1000,
        tickAmp: amp(tickPulse), tockAmp: amp(tockPulse), foldCount: foldCount
    )
}

// MARK: - Process files one at a time

func processFile(_ filename: String) {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(filename)
    guard let buf = try? WAVReader.read(url: url) else {
        print("  Failed to read \(filename)")
        return
    }
    let result = pipeline.measure(buf)
    let short = String(filename.dropFirst(24).dropLast(4))

    print("\(short) (Q=\(Int(result.qualityScore * 100))%, ticks=\(result.tickCount), rate=\(String(format: "%+.1f", result.rateErrorSecondsPerDay))s/day)")

    let hpCutoffs: [Double] = [0, 500, 1000, 1500, 2000, 3000, 4000]

    for hp in hpCutoffs {
        let label = hp == 0 ? "raw    " : "HP\(String(format: "%4.0f", hp))Hz"
        let signal: [Float]
        if hp > 0 {
            signal = conditioner.bandpassFilter(
                buf.samples, sampleRate: buf.sampleRate,
                lowCutoff: hp, highCutoff: min(buf.sampleRate / 2 - 100, 20000)
            )
        } else {
            signal = buf.samples
        }

        if let fr = foldAndMeasure(
            signal: signal, sampleRate: buf.sampleRate,
            tickTimings: result.tickTimings, rateError: result.rateErrorSecondsPerDay,
            rate: result.snappedRate, smoothMs: 3.0, threshFrac: 0.20
        ) {
            let tickStr = fr.tickAmp.map { String(format: "%3.0f°", $0) } ?? "---"
            let tockStr = fr.tockAmp.map { String(format: "%3.0f°", $0) } ?? "---"
            let avg: Double?
            if let t = fr.tickAmp, let k = fr.tockAmp { avg = (t + k) / 2 }
            else { avg = fr.tickAmp ?? fr.tockAmp }
            let avgStr = avg.map { String(format: "%3.0f°", $0) } ?? "---"
            print("  \(label): tick=\(String(format: "%5.2f", fr.tickPulseMs))ms(\(tickStr)) tock=\(String(format: "%5.2f", fr.tockPulseMs))ms(\(tockStr)) avg=\(avgStr)")
        } else {
            print("  \(label): measurement failed")
        }
    }
    print()
}

print("=== High-Pass Filter Experiment for Amplitude Estimation ===")
print("Lift angle: \(liftAngle)° | Fold: phase-aligned, 3ms smooth, 20% threshold")
print(String(repeating: "=", count: 80))
print()

// Process specific files
let targetFiles = [
    "watchbeat_20260414_094252_21600bph_q80.wav",
    "watchbeat_20260414_094438_21600bph_q77.wav",
    "watchbeat_20260414_094633_21600bph_q67.wav",
    "watchbeat_20260414_094756_21600bph_q58.wav",
    "watchbeat_20260414_095059_21600bph_q62.wav",
    "watchbeat_20260414_094354_21600bph_q56.wav",
    "watchbeat_20260414_094520_21600bph_q66.wav",
    "watchbeat_20260414_094850_21600bph_q42.wav",
]

for f in targetFiles {
    processFile(f)
}
