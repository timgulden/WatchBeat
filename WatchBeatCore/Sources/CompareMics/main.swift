import Foundation
import Accelerate
import WatchBeatCore

// Usage:
//   swift run CompareMics                    -> defaults to Marginal_Headphone_q30.wav + Weak_Internal_q21.wav
//   swift run CompareMics <file1.wav> ...    -> specific files
//   swift run CompareMics <dir>              -> all .wav in dir (legacy behavior)

let args = Array(CommandLine.arguments.dropFirst())
let baseDir = "SoundSamples"
FileHandle.standardError.write("args=\(args)\n".data(using: .utf8)!)

func resolve(_ path: String) -> String {
    if FileManager.default.fileExists(atPath: path) { return path }
    let joined = (baseDir as NSString).appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: joined) { return joined }
    return path
}

func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    return exists && isDir.boolValue
}

let files: [String] = {
    if args.isEmpty {
        return ["Marginal_Headphone_q30.wav", "Weak_Internal_q21.wav"].map { resolve($0) }
    }
    if args.count == 1, isDirectory(args[0]) {
        return (try? FileManager.default.contentsOfDirectory(atPath: args[0]))?
            .filter { $0.hasSuffix(".wav") }
            .sorted()
            .map { (args[0] as NSString).appendingPathComponent($0) } ?? []
    }
    return args.map { resolve($0) }
}()
FileHandle.standardError.write("files=\(files.count): \(files)\n".data(using: .utf8)!)

func load(_ path: String) -> (AudioBuffer, String)? {
    let url = URL(fileURLWithPath: path)
    guard let buf = try? WAVReader.read(url: url) else { return nil }
    return (buf, url.lastPathComponent)
}

// MARK: - Brick-wall FFT filter (offline)

func nextPow2(_ n: Int) -> Int {
    var v = n - 1
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16
    return v + 1
}

func fftFilter(_ samples: [Float], sampleRate: Double, lowHz: Double, highHz: Double) -> [Float] {
    let n = samples.count
    let fftLen = nextPow2(n)
    var padded = [Float](repeating: 0, count: fftLen)
    padded.replaceSubrange(0..<n, with: samples)

    let log2n = vDSP_Length(log2(Double(fftLen)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return samples }
    defer { vDSP_destroy_fftsetup(setup) }

    let half = fftLen / 2
    var real = [Float](repeating: 0, count: half)
    var imag = [Float](repeating: 0, count: half)

    padded.withUnsafeBufferPointer { buf in
        for i in 0..<half {
            real[i] = buf[2 * i]
            imag[i] = buf[2 * i + 1]
        }
    }

    real.withUnsafeMutableBufferPointer { r in
        imag.withUnsafeMutableBufferPointer { im in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

            let binHz = sampleRate / Double(fftLen)
            let loBin = Int(lowHz / binHz)
            let hiBin = min(half - 1, Int(highHz / binHz))

            for i in 0..<half {
                if i < loBin || i > hiBin {
                    r[i] = 0
                    im[i] = 0
                }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        }
    }

    var out = [Float](repeating: 0, count: fftLen)
    out.withUnsafeMutableBufferPointer { buf in
        for i in 0..<half {
            buf[2 * i] = real[i]
            buf[2 * i + 1] = imag[i]
        }
    }

    let scale: Float = 1.0 / Float(2 * fftLen)
    vDSP_vsmul(out, 1, [scale], &out, 1, vDSP_Length(fftLen))

    return Array(out.prefix(n))
}

// MARK: - Pipeline wrapper

let pipeline = MeasurementPipeline()

struct RunResult {
    let quality: Int
    let residualMs: Double   // non-saturating metric: inverted from quality
    let rateError: Double
    let beatErrorMs: Double?
    let ticks: Int
    let measuredHz: Double
    let snappedBph: Int
}

// quality = exp(-residualStd_seconds / 0.001)
// => residualStd_ms = -log(quality)
func run(_ buf: AudioBuffer) -> RunResult {
    let (r, d) = pipeline.measureWithDiagnostics(buf)
    let q = max(r.qualityScore, 1e-9)
    let residualMs = -log(q)  // since divisor is exactly 1ms
    return RunResult(
        quality: Int(r.qualityScore * 100),
        residualMs: residualMs,
        rateError: r.rateErrorSecondsPerDay,
        beatErrorMs: r.beatErrorMilliseconds,
        ticks: r.tickCount,
        measuredHz: d.periodEstimate.measuredHz,
        snappedBph: r.snappedRate.rawValue
    )
}

func fileInfo(_ buf: AudioBuffer) -> String {
    let duration = Double(buf.samples.count) / buf.sampleRate
    var peak: Float = 0
    vDSP_maxmgv(buf.samples, 1, &peak, vDSP_Length(buf.samples.count))
    var rms: Float = 0
    vDSP_rmsqv(buf.samples, 1, &rms, vDSP_Length(buf.samples.count))
    return "sr=\(Int(buf.sampleRate))Hz dur=\(String(format: "%.1fs", duration)) peak=\(String(format: "%.3f", peak)) rms=\(String(format: "%.4f", rms))"
}

func fmtResult(_ r: RunResult) -> String {
    let rms = r.residualMs > 20 ? "  n/a" : String(format: "%5.2f", r.residualMs)
    let rate = String(format: "%+7.1f", r.rateError)
    let beat = r.beatErrorMs.map { String(format: "%5.2f", $0) } ?? "  n/a"
    return "q=\(String(format: "%3d", r.quality))%  res=\(rms)ms  bph=\(r.snappedBph)  ticks=\(String(format: "%3d", r.ticks))  rate=\(rate)s/d  beat=\(beat)ms"
}

// MARK: - Spectral comparison (where does the tick energy live?)

func tickVsGapSpectrum(_ buf: AudioBuffer) -> [(band: String, tickDb: Float, gapDb: Float, snrDb: Float)] {
    // Use the actual detected rate so we align windows correctly
    let (r, _) = pipeline.measureWithDiagnostics(buf)
    let rate = r.snappedRate
    let sr = buf.sampleRate
    let period = rate.nominalPeriodSeconds
    let periodSamples = Int(round(period * sr))
    let halfPeriod = periodSamples / 2

    var sq = [Float](repeating: 0, count: buf.samples.count)
    vDSP_vsq(buf.samples, 1, &sq, 1, vDSP_Length(buf.samples.count))

    let n = buf.samples.count
    let nPeriods = n / periodSamples
    guard nPeriods >= 5 else { return [] }

    // Short window (~3 ms) centered on the tick peak — longer windows wash out the transient
    let tickWin = max(64, Int(0.003 * sr))

    // Find phase via max-energy position in first period
    var tickOffsets: [Int] = []
    for p in 0..<nPeriods {
        let start = p * periodSamples
        var maxE: Float = 0
        var maxI = 0
        var runSum: Float = 0
        for i in 0..<min(tickWin, periodSamples) where start + i < n { runSum += sq[start + i] }
        maxE = runSum; maxI = 0
        for i in 1..<(periodSamples - tickWin) where start + i + tickWin < n {
            runSum += sq[start + i + tickWin - 1] - sq[start + i - 1]
            if runSum > maxE { maxE = runSum; maxI = i }
        }
        tickOffsets.append(maxI)
    }
    let tickPhase = tickOffsets.sorted()[tickOffsets.count / 2]

    var tickWindows: [[Float]] = []
    var gapWindows: [[Float]] = []
    for p in 0..<nPeriods {
        let tStart = p * periodSamples + tickPhase
        let gStart = tStart + halfPeriod
        if tStart + tickWin < n {
            tickWindows.append(Array(buf.samples[tStart..<tStart+tickWin]))
        }
        if gStart + tickWin < n {
            gapWindows.append(Array(buf.samples[gStart..<gStart+tickWin]))
        }
    }

    guard !tickWindows.isEmpty && !gapWindows.isEmpty else { return [] }

    let bands: [(name: String, lo: Double, hi: Double)] = [
        ("0.1-0.25k", 100, 250),
        ("0.25-0.5k", 250, 500),
        ("0.5-1k",    500, 1000),
        ("1-2k",      1000, 2000),
        ("2-4k",      2000, 4000),
        ("4-8k",      4000, 8000),
        ("8-16k",     8000, min(16000, sr/2 - 100)),
    ]

    var results: [(band: String, tickDb: Float, gapDb: Float, snrDb: Float)] = []
    for b in bands {
        guard b.hi > b.lo else { continue }
        func bandEnergy(_ windows: [[Float]]) -> Float {
            var total: Float = 0
            for w in windows { total += fftBandEnergy(w, sampleRate: sr, lo: b.lo, hi: b.hi) }
            return total / Float(windows.count)
        }
        let te = bandEnergy(tickWindows)
        let ge = bandEnergy(gapWindows)
        let tdb = 10 * log10(max(te, 1e-30))
        let gdb = 10 * log10(max(ge, 1e-30))
        results.append((b.name, tdb, gdb, tdb - gdb))
    }
    return results
}

func fftBandEnergy(_ x: [Float], sampleRate: Double, lo: Double, hi: Double) -> Float {
    let n = x.count
    let fftLen = nextPow2(n)
    var padded = [Float](repeating: 0, count: fftLen)
    padded.replaceSubrange(0..<n, with: x)
    var hann = [Float](repeating: 0, count: fftLen)
    vDSP_hann_window(&hann, vDSP_Length(fftLen), Int32(vDSP_HANN_NORM))
    vDSP_vmul(padded, 1, hann, 1, &padded, 1, vDSP_Length(fftLen))

    let log2n = vDSP_Length(log2(Double(fftLen)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 0 }
    defer { vDSP_destroy_fftsetup(setup) }

    let half = fftLen / 2
    var real = [Float](repeating: 0, count: half)
    var imag = [Float](repeating: 0, count: half)
    padded.withUnsafeBufferPointer { buf in
        for i in 0..<half { real[i] = buf[2*i]; imag[i] = buf[2*i+1] }
    }
    var mags = [Float](repeating: 0, count: half)
    real.withUnsafeMutableBufferPointer { r in
        imag.withUnsafeMutableBufferPointer { im in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
        }
    }
    let binHz = sampleRate / Double(fftLen)
    let loBin = max(0, Int(lo / binHz))
    let hiBin = min(half - 1, Int(hi / binHz))
    var sum: Float = 0
    if hiBin >= loBin {
        for i in loBin...hiBin { sum += mags[i] }
    }
    return sum
}

// MARK: - Report per file

func report(_ path: String) {
    guard let (buf, name) = load(path) else {
        print("(failed to load \(path))")
        return
    }

    print("\n")
    print(String(repeating: "=", count: 78))
    print("  \(name)")
    print(String(repeating: "=", count: 78))
    print("  \(fileInfo(buf))")

    let base = run(buf)
    print("\n  Baseline: \(fmtResult(base))")

    print("\n  Tick-vs-gap energy by band (3ms tick window, centered on peak):")
    print("    band        tick(dB)  gap(dB)  snr(dB)")
    for row in tickVsGapSpectrum(buf) {
        print("    \(row.band.padding(toLength: 10, withPad: " ", startingAt: 0))  \(String(format: "%7.1f", row.tickDb))  \(String(format: "%7.1f", row.gapDb))  \(String(format: "%+6.1f", row.snrDb))")
    }

    print("\n  Highpass sweep:")
    print("    cutoff       result")
    let hpCutoffs: [Double] = [0, 100, 300, 500, 1000, 2000, 3000, 4000, 6000, 8000, 10000, 12000, 16000, 20000]
    var bestHp: (cutoff: Double, res: Double)? = nil
    for hp in hpCutoffs {
        let filtered: AudioBuffer = hp == 0 ? buf : AudioBuffer(
            samples: fftFilter(buf.samples, sampleRate: buf.sampleRate, lowHz: hp, highHz: buf.sampleRate / 2),
            sampleRate: buf.sampleRate
        )
        let r = run(filtered)
        print("    \(String(format: "%5.0fHz", hp))     \(fmtResult(r))")
        if r.quality >= 30 && (bestHp == nil || r.residualMs < bestHp!.res) {
            bestHp = (hp, r.residualMs)
        }
    }

    print("\n  Bandpass sweep:")
    print("    band             result")
    let bands: [(Double, Double)] = [
        (100, 500),
        (300, 1000),
        (500, 2000),
        (1000, 3000),
        (2000, 5000),
        (3000, 8000),
        (4000, 10000),
        (5000, 12000),
        (6000, 16000),
        (8000, 18000),
        (10000, 20000),
        (2000, 20000),
        (4000, 20000),
        (6000, 20000),
    ]
    var bestBp: (band: (Double, Double), res: Double)? = nil
    for (lo, hi) in bands {
        let filtered = AudioBuffer(
            samples: fftFilter(buf.samples, sampleRate: buf.sampleRate, lowHz: lo, highHz: hi),
            sampleRate: buf.sampleRate
        )
        let r = run(filtered)
        print("    \(String(format: "%5.0f-%5.0fHz", lo, hi))  \(fmtResult(r))")
        if r.quality >= 30 && (bestBp == nil || r.residualMs < bestBp!.res) {
            bestBp = ((lo, hi), r.residualMs)
        }
    }

    if let b = bestHp {
        print("\n  Best highpass: \(String(format: "%.0f", b.cutoff))Hz  res=\(String(format: "%.2f", b.res))ms")
    }
    if let b = bestBp {
        print("  Best bandpass: \(String(format: "%.0f-%.0fHz", b.band.0, b.band.1))  res=\(String(format: "%.2f", b.res))ms")
    }
}

// MARK: - Batch comparison: baseline vs highpass for every file

func batchCompare(cutoff: Double) {
    print("\n")
    print(String(repeating: "=", count: 100))
    print("  BATCH: baseline vs highpass \(Int(cutoff))Hz")
    print(String(repeating: "=", count: 100))
    print("  \("file".padding(toLength: 50, withPad: " ", startingAt: 0))  baseline                          highpass \(Int(cutoff))Hz")
    print("  \("".padding(toLength: 50, withPad: " ", startingAt: 0))  q%  res(ms)  bph    rate(s/d)    q%  res(ms)  bph    rate(s/d)   Δres(ms)")

    var baselineResSum: Double = 0
    var filteredResSum: Double = 0
    var baselinePassCount = 0
    var filteredPassCount = 0
    var wins = 0
    var losses = 0
    var rateFlips = 0
    var total = 0

    for path in files {
        FileHandle.standardError.write("[\(path)] loading\n".data(using: .utf8)!)
        guard let (buf, name) = load(path) else { FileHandle.standardError.write("  load failed\n".data(using: .utf8)!); continue }
        total += 1
        FileHandle.standardError.write("  baseline run\n".data(using: .utf8)!)
        let base = run(buf)
        FileHandle.standardError.write("  filtering\n".data(using: .utf8)!)
        let filtSamples = fftFilter(buf.samples, sampleRate: buf.sampleRate, lowHz: cutoff, highHz: buf.sampleRate / 2)
        FileHandle.standardError.write("  filtered run\n".data(using: .utf8)!)
        let filtered = run(AudioBuffer(samples: filtSamples, sampleRate: buf.sampleRate))
        FileHandle.standardError.write("  done\n".data(using: .utf8)!)

        if base.quality >= 30 { baselinePassCount += 1 }
        if filtered.quality >= 30 { filteredPassCount += 1 }
        if base.residualMs < 20 { baselineResSum += base.residualMs }
        if filtered.residualMs < 20 { filteredResSum += filtered.residualMs }

        let deltaRes = filtered.residualMs - base.residualMs
        if filtered.quality > base.quality + 3 { wins += 1 }
        else if filtered.quality + 3 < base.quality { losses += 1 }
        if base.snappedBph != filtered.snappedBph { rateFlips += 1 }

        let shortName = String(name.prefix(50)).padding(toLength: 50, withPad: " ", startingAt: 0)
        let bRes = base.residualMs > 20 ? "  n/a" : String(format: "%5.2f", base.residualMs)
        let fRes = filtered.residualMs > 20 ? "  n/a" : String(format: "%5.2f", filtered.residualMs)
        let dRes = (base.residualMs > 20 || filtered.residualMs > 20) ? "  n/a" : String(format: "%+5.2f", deltaRes)
        let flip = base.snappedBph != filtered.snappedBph ? " !" : ""
        print("  \(shortName)  \(String(format: "%3d", base.quality))%  \(bRes)  \(String(format: "%5d", base.snappedBph))  \(String(format: "%+7.1f", base.rateError))      \(String(format: "%3d", filtered.quality))%  \(fRes)  \(String(format: "%5d", filtered.snappedBph))  \(String(format: "%+7.1f", filtered.rateError))   \(dRes)\(flip)")
    }

    print("\n  Summary (\(total) files):")
    print("    Passing (q>=30%): baseline=\(baselinePassCount)  highpass=\(filteredPassCount)")
    print("    Wins (highpass q better by >3pp):   \(wins)")
    print("    Losses (highpass q worse by >3pp):  \(losses)")
    print("    Rate-snap flips: \(rateFlips)   (⚑ in table)")
}

// MARK: - Multi-cutoff sweep

func cutoffSweep(_ cutoffs: [Double]) {
    print("\n")
    print(String(repeating: "=", count: 130))
    print("  HIGHPASS CUTOFF SWEEP — quality % per file")
    print(String(repeating: "=", count: 130))

    let colHeader = cutoffs.map { String(format: "%4.0fk", $0 / 1000) }.joined(separator: "   ")
    print("  \("file".padding(toLength: 48, withPad: " ", startingAt: 0))  base    \(colHeader)")

    var allResults: [(name: String, baseQ: Int, baseRes: Double, baseBph: Int, qs: [Int], rs: [Double], bphs: [Int])] = []

    for path in files {
        FileHandle.standardError.write("[\(path)]\n".data(using: .utf8)!)
        guard let (buf, name) = load(path) else { continue }
        let base = run(buf)

        var qs: [Int] = []; var rs: [Double] = []; var bphs: [Int] = []
        for c in cutoffs {
            let filt = fftFilter(buf.samples, sampleRate: buf.sampleRate, lowHz: c, highHz: buf.sampleRate / 2)
            let r = run(AudioBuffer(samples: filt, sampleRate: buf.sampleRate))
            qs.append(r.quality); rs.append(r.residualMs); bphs.append(r.snappedBph)
        }
        allResults.append((name, base.quality, base.residualMs, base.snappedBph, qs, rs, bphs))

        let shortName = String(name.prefix(48)).padding(toLength: 48, withPad: " ", startingAt: 0)
        let baseCol = String(format: "%3d%%", base.quality)
        let cols = qs.map { String(format: "%3d%%", $0) }.joined(separator: "   ")
        print("  \(shortName)  \(baseCol)    \(cols)")
    }

    print("\n  Summary by cutoff:")
    print("    cutoff      pass(q>=30)   mean_res(ms)   med_res(ms)   wins   losses   rate_flips")

    let basePass = allResults.filter { $0.baseQ >= 30 }.count
    let baseResVals = allResults.compactMap { $0.baseRes <= 20 ? $0.baseRes : nil }
    let bMean = baseResVals.isEmpty ? 0 : baseResVals.reduce(0, +) / Double(baseResVals.count)
    let bMed = baseResVals.isEmpty ? 0 : baseResVals.sorted()[baseResVals.count / 2]
    print(String(format: "    baseline     %2d/%2d        %6.3f          %6.3f        -      -        -",
                 basePass, allResults.count, bMean, bMed))

    for (i, c) in cutoffs.enumerated() {
        let pass = allResults.filter { $0.qs[i] >= 30 }.count
        let vals = allResults.compactMap { $0.rs[i] <= 20 ? $0.rs[i] : nil }
        let mean = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
        let med = vals.isEmpty ? 0 : vals.sorted()[vals.count / 2]
        let wins = allResults.filter { $0.qs[i] > $0.baseQ + 3 }.count
        let losses = allResults.filter { $0.qs[i] + 3 < $0.baseQ }.count
        let flips = allResults.filter { $0.bphs[i] != $0.baseBph }.count
        print(String(format: "    %5.0fHz      %2d/%2d        %6.3f          %6.3f        %2d      %2d        %2d",
                     c, pass, allResults.count, mean, med, wins, losses, flips))
    }

    print("\n  Best cutoff per file (lowest residual among passing):")
    for r in allResults {
        var best: (c: Double, res: Double, q: Int)? = nil
        for (i, c) in cutoffs.enumerated() where r.qs[i] >= 30 {
            if best == nil || r.rs[i] < best!.res { best = (c, r.rs[i], r.qs[i]) }
        }
        let short = String(r.name.prefix(48)).padding(toLength: 48, withPad: " ", startingAt: 0)
        if let b = best {
            print("    \(short)  \(String(format: "%5.0fHz  q=%d%%  res=%.3fms", b.c, b.q, b.res))")
        } else {
            print("    \(short)  (none passed)")
        }
    }
}

if args.count == 1, isDirectory(args[0]) {
    cutoffSweep([4000, 5000, 6000, 7000, 8000, 9000, 10000])
} else if args.isEmpty || args.count <= 2 {
    for f in files { report(f) }
} else {
    cutoffSweep([4000, 5000, 6000, 7000, 8000, 9000, 10000])
}
