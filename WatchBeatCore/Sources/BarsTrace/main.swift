// BarsTrace — diagnostic that replays the iOS app's SpectrogramMonitor
// pipeline against a WAV file and dumps the RAW (un-normalized) Goertzel
// magnitudes at each standard beat rate, comparing the legacy 20 Hz
// (50 ms hop) bar envelope against the new 100 Hz (10 ms hop) envelope.
//
// Built to verify that the post-fix 100 Hz envelope collapses the
// aliasing-driven 8 Hz / 10 Hz bumps that appear in the 20 Hz envelope
// for sharp-tick NH35 recordings.
//
// Pipeline (mirrors SpectrogramMonitor.swift):
//   1. STFT, 1024-pt Hann window, 10 ms hop, full file.
//   2. Pick the best 4–22 kHz bin by peak/median rhythmicity (same
//      scorer the monitor uses); band = best ± 500 Hz.
//   3. Build TWO band-energy envelopes from the same per-bin STFTs:
//        (a) 100 Hz envelope (every 10-ms frame, anti-aliased)
//        (b) 20 Hz envelope (every 5th frame, legacy / aliasing-prone)
//   4. Detrend, Goertzel at each standard beat rate, report raw mags.

import Foundation
import Accelerate
import WatchBeatCore

guard CommandLine.arguments.count > 1 else {
    print("Usage: BarsTrace <file.wav> [<file2.wav> ...]")
    exit(1)
}

let fftWindowSize = 1024
let log2n = vDSP_Length(log2(Double(fftWindowSize)))
var hannWindow = [Float](repeating: 0, count: fftWindowSize)
vDSP_hann_window(&hannWindow, vDSP_Length(fftWindowSize), Int32(vDSP_HANN_NORM))
let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
defer { vDSP_destroy_fftsetup(fftSetup) }

func goertzelMagnitude(series: [Float], frameRate: Double, targetHz: Double) -> Double {
    let n = series.count
    let omega = 2.0 * .pi * targetHz / frameRate
    let coeff = 2.0 * cos(omega)
    var sPrev: Double = 0
    var sPrev2: Double = 0
    for i in 0..<n {
        let s = Double(series[i]) + coeff * sPrev - sPrev2
        sPrev2 = sPrev
        sPrev = s
    }
    let mag2 = sPrev * sPrev + sPrev2 * sPrev2 - coeff * sPrev * sPrev2
    return sqrt(max(0, mag2))
}

func goertzelOnDetrended(_ series: [Float], frameRate: Double, target: Double) -> Double {
    var s = series
    var mean: Float = 0
    vDSP_meanv(s, 1, &mean, vDSP_Length(s.count))
    var neg = -mean
    vDSP_vsadd(s, 1, &neg, &s, 1, vDSP_Length(s.count))
    return goertzelMagnitude(series: s, frameRate: frameRate, targetHz: target)
}

func processFile(_ path: String) {
    let url = URL(fileURLWithPath: path)
    let buf: AudioBuffer
    do { buf = try WAVReader.read(url: url) }
    catch { print("\(path): ERROR reading: \(error)"); return }

    let samples = buf.samples
    let sampleRate = buf.sampleRate
    let nSamp = samples.count
    let dur = Double(nSamp) / sampleRate

    print("")
    print("=== \(url.lastPathComponent) ===")
    print(String(format: "  sampleRate=%.0f Hz, duration=%.2f s", sampleRate, dur))

    // 10 ms hop — gives both the new 100 Hz envelope directly and the
    // legacy 20 Hz envelope via 5× decimation.
    let hopSec = 0.010
    let hop = Int(sampleRate * hopSec)
    let frameRate100 = sampleRate / Double(hop)
    let frameRate20  = frameRate100 / 5.0
    let nBins = fftWindowSize / 2
    let nFrames = max(1, (nSamp - fftWindowSize) / hop + 1)

    // Per-bin magnitude time series at 100 Hz.
    var perBin = [[Float]](repeating: [Float](repeating: 0, count: nFrames), count: nBins)
    var seg = [Float](repeating: 0, count: fftWindowSize)
    var realPart = [Float](repeating: 0, count: nBins)
    var imagPart = [Float](repeating: 0, count: nBins)
    for t in 0..<nFrames {
        let startIdx = t * hop
        for i in 0..<fftWindowSize {
            seg[i] = samples[startIdx + i] * hannWindow[i]
        }
        for i in 0..<nBins {
            realPart[i] = seg[2 * i]
            imagPart[i] = seg[2 * i + 1]
        }
        realPart.withUnsafeMutableBufferPointer { rp in
            imagPart.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        for k in 0..<nBins {
            let re = realPart[k]
            let im = imagPart[k]
            perBin[k][t] = sqrt(re * re + im * im)
        }
    }

    // Best-band scorer (matches SpectrogramMonitor.updateBestBand).
    let beatHz: [Double] = StandardBeatRate.allCases.map { $0.hz }
    let binsPerHz = Double(fftWindowSize) / sampleRate
    let firstBin = max(1, Int(4000.0 * binsPerHz))
    let lastBin = min(nBins - 1, Int(22000.0 * binsPerHz))
    let bandHalfBins = max(2, Int(500.0 * binsPerHz))

    var bestBin = -1
    var bestScore: Double = 0
    for k in firstBin...lastBin {
        var series = perBin[k]
        var mean: Float = 0
        vDSP_meanv(series, 1, &mean, vDSP_Length(nFrames))
        var negMean = -mean
        vDSP_vsadd(series, 1, &negMean, &series, 1, vDSP_Length(nFrames))
        var peak: Double = 0
        for r in beatHz {
            let mag = goertzelMagnitude(series: series, frameRate: frameRate100, targetHz: r)
            if mag > peak { peak = mag }
        }
        var bg: [Double] = []
        var f = 3.0
        while f <= 12.0 {
            var near = false
            for r in beatHz where abs(f - r) < 0.5 { near = true; break }
            if !near {
                bg.append(goertzelMagnitude(series: series, frameRate: frameRate100, targetHz: f))
            }
            f += 0.25
        }
        guard !bg.isEmpty else { continue }
        bg.sort()
        let median = bg[bg.count / 2]
        let score = peak / max(median, 1e-12)
        if score > bestScore {
            bestScore = score
            bestBin = k
        }
    }
    guard bestBin >= 0 else { print("  no rhythmic band found"); return }
    let bandLow = max(firstBin, bestBin - bandHalfBins)
    let bandHigh = min(lastBin, bestBin + bandHalfBins)
    let bestHz = (Double(bestBin) + 0.5) * sampleRate / Double(fftWindowSize)
    print(String(format: "  best band: bin=%d (%.0f Hz), score=%.2f, ±500 Hz",
                 bestBin, bestHz, bestScore))

    // 100 Hz band-energy envelope.
    var env100 = [Float](repeating: 0, count: nFrames)
    for t in 0..<nFrames {
        var s: Float = 0
        for k in bandLow...bandHigh { s += perBin[k][t] }
        env100[t] = s
    }

    // 20 Hz envelope = every 5th frame of env100 (matches the legacy
    // trace-derived bar input).
    var env20: [Float] = []
    env20.reserveCapacity(nFrames / 5 + 1)
    var t = 0
    while t < nFrames {
        env20.append(env100[t])
        t += 5
    }

    let barWindowSec = 5.0
    let n100 = Int(barWindowSec / hopSec)             // 500 frames
    let n20  = Int(barWindowSec / (hopSec * 5))       // 100 frames
    guard env100.count >= n100, env20.count >= n20 else {
        print("  too short for 5-s bar window"); return
    }

    // Sliding 1-s steps; for each, run Goertzel at every standard rate
    // against both envelopes and compare.
    let stepSec = 1.0
    let stepFrames100 = Int(stepSec / hopSec)
    let stepFrames20  = Int(stepSec / (hopSec * 5))

    print("  Goertzel comparison — 20 Hz (legacy) vs 100 Hz (anti-aliased):")
    let labelLine = StandardBeatRate.allCases.map { String(format: "%6d", $0.rawValue) }.joined(separator: " ")
    print("    t(s)  src  | \(labelLine)  | 6:8")

    var endLo = n20
    var endHi = n100
    var means20: [Double] = Array(repeating: 0, count: StandardBeatRate.allCases.count)
    var means100: [Double] = Array(repeating: 0, count: StandardBeatRate.allCases.count)
    var rowCount = 0
    while endLo <= env20.count && endHi <= env100.count {
        let slice20  = Array(env20[(endLo - n20)..<endLo])
        let slice100 = Array(env100[(endHi - n100)..<endHi])
        var row20: [Double] = []
        var row100: [Double] = []
        for rate in StandardBeatRate.allCases {
            row20.append(goertzelOnDetrended(slice20, frameRate: frameRate20, target: rate.hz))
            row100.append(goertzelOnDetrended(slice100, frameRate: frameRate100, target: rate.hz))
        }
        for j in 0..<row20.count { means20[j] += row20[j]; means100[j] += row100[j] }
        rowCount += 1

        let t = Double(endHi) / frameRate100
        let row20Fmt  = row20.map  { String(format: "%6.2f", $0) }.joined(separator: " ")
        let row100Fmt = row100.map { String(format: "%6.2f", $0) }.joined(separator: " ")
        let r6_20  = row20[2],  r8_20  = row20[4]
        let r6_100 = row100[2], r8_100 = row100[4]
        let ratio20  = r8_20  > 0 ? r6_20  / r8_20  : .infinity
        let ratio100 = r8_100 > 0 ? r6_100 / r8_100 : .infinity
        print(String(format: "    %4.1f  20Hz | %@  | %5.2f", t, row20Fmt, ratio20))
        print(String(format: "          100Hz| %@  | %5.2f", row100Fmt, ratio100))

        endLo += stepFrames20
        endHi += stepFrames100
    }

    if rowCount > 0 {
        for j in 0..<means20.count {
            means20[j]  /= Double(rowCount)
            means100[j] /= Double(rowCount)
        }
        let labels = StandardBeatRate.allCases.map { "\($0.rawValue)" }
        print("  --- mean raw magnitudes ---")
        print("    20 Hz : " + zip(labels, means20).map  { String(format: "%@:%.2f", $0.0, $0.1) }.joined(separator: "  "))
        print("    100 Hz: " + zip(labels, means100).map { String(format: "%@:%.2f", $0.0, $0.1) }.joined(separator: "  "))
        let ratio20  = means20[4]  > 0 ? means20[2]  / means20[4]  : .infinity
        let ratio100 = means100[4] > 0 ? means100[2] / means100[4] : .infinity
        print(String(format: "    ⇒ 21600/28800 ratio: 20 Hz = %.2fx, 100 Hz = %.2fx", ratio20, ratio100))
    }
}

for arg in CommandLine.arguments.dropFirst() {
    processFile(arg)
}
