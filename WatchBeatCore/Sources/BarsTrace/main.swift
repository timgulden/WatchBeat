// BarsTrace — diagnostic that replays the iOS app's SpectrogramMonitor
// pipeline against a WAV file and dumps the RAW (un-normalized) Goertzel
// magnitudes at each standard beat rate.
//
// Pipeline (mirrors SpectrogramMonitor.swift):
//   1. STFT, 1024-pt Hann window, 10 ms hop — for BAND SELECTION only.
//   2. Pick the best 4–22 kHz bin by peak/median rhythmicity.
//   3. Build 100 Hz band-energy envelope via SignalConditioner.bandpassEnergyEnvelope
//      (time-domain bandpass + square + decimate), matching the shared
//      helper used in SpectrogramMonitor.
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
    let bestHz = (Double(bestBin) + 0.5) * sampleRate / Double(fftWindowSize)
    print(String(format: "  best band: bin=%d (%.0f Hz), score=%.2f, ±500 Hz",
                 bestBin, bestHz, bestScore))

    // Build the 100 Hz band-energy envelope via the shared helper that
    // the iOS app's SpectrogramMonitor now uses (time-domain bandpass +
    // square + decimate). Matches the production path exactly.
    let conditioner = SignalConditioner()
    let envelope = conditioner.bandpassEnergyEnvelope(
        samples: samples,
        sampleRate: sampleRate,
        centerHz: bestHz,
        halfWidthHz: 500.0,
        targetRateHz: 100.0
    )
    let envelopeRate = 100.0

    let barWindowSec = 5.0
    let nWindow = Int(barWindowSec * envelopeRate)
    guard envelope.count >= nWindow else {
        print("  too short for 5-s bar window"); return
    }

    print("  Raw Goertzel magnitudes (sliding 1-s steps, 5-s window):")
    let labelLine = StandardBeatRate.allCases.map { String(format: "%6d", $0.rawValue) }.joined(separator: " ")
    print("    t(s)  | \(labelLine)  | 6:8")

    let stepFrames = Int(envelopeRate)  // 1-s step
    var end = nWindow
    var means: [Double] = Array(repeating: 0, count: StandardBeatRate.allCases.count)
    var rowCount = 0
    while end <= envelope.count {
        let slice = Array(envelope[(end - nWindow)..<end])
        var row: [Double] = []
        for rate in StandardBeatRate.allCases {
            row.append(goertzelOnDetrended(slice, frameRate: envelopeRate, target: rate.hz))
        }
        for j in 0..<row.count { means[j] += row[j] }
        rowCount += 1

        let t = Double(end) / envelopeRate
        let rowFmt = row.map { String(format: "%6.2f", $0) }.joined(separator: " ")
        let r6 = row[2], r8 = row[4]
        let ratio = r8 > 0 ? r6 / r8 : .infinity
        print(String(format: "    %4.1f  | %@  | %5.2f", t, rowFmt, ratio))
        end += stepFrames
    }

    if rowCount > 0 {
        for j in 0..<means.count { means[j] /= Double(rowCount) }
        let labels = StandardBeatRate.allCases.map { "\($0.rawValue)" }
        print("  --- mean raw magnitudes ---")
        print("    " + zip(labels, means).map { String(format: "%@:%.2f", $0.0, $0.1) }.joined(separator: "  "))
        let ratio = means[4] > 0 ? means[2] / means[4] : .infinity
        print(String(format: "    ⇒ 21600/28800 mean raw ratio: %.2fx", ratio))
    }
}

for arg in CommandLine.arguments.dropFirst() {
    processFile(arg)
}
