import AVFoundation
import Accelerate
import WatchBeatCore

/// Real-time producer of the Listen-screen visualizations.
///
/// Computes a short-time FFT every ~50 ms over the most recent ~21 ms of
/// audio, then derives:
///   - One trace sample per STFT slice = total energy in the algorithm's
///     current best band (or broadband if no band has been selected yet).
///     Published into SpectrogramData.trace.
///   - Once per ~1 s: a fresh best-band selection (max-rhythmicity scan
///     over all 4–22 kHz bins).
///   - Once per ~250 ms: Goertzel magnitudes at each standard beat rate
///     against the recent trace data → rate bars.
///
/// Audio capture mirrors FrequencyMonitor's lifecycle (own AVAudioEngine
/// during Listen, external sample feed during Recording — same data,
/// same monitor, different transport).
final class SpectrogramMonitor: @unchecked Sendable {

    let data: SpectrogramData

    private var engine: AVAudioEngine?
    private(set) var configInfo: String = ""

    // STFT setup
    private let fftWindowSize = 1024
    private let log2n: vDSP_Length
    private let hannWindow: [Float]
    private let fftSetup: FFTSetup?
    private var sampleRate: Double = 48000

    // Rolling raw audio buffer.
    private let rollingBufferDuration: Double = 16.0
    private var rollingBuffer: [Float] = []
    private var rollingBufferSize: Int = 0
    private var samplesAccumulated: Int = 0

    // Trace-emit cadence (matches one STFT hop).
    private var samplesSinceLastColumn: Int = 0
    private var samplesPerColumn: Int = 2400
    /// When trace buffer first hit "full" (totalTraceWritten ==
    /// traceSampleCount). Trace emissions pause briefly here so the
    /// trace doesn't scroll during the picker's analysis-decision time
    /// for a successful first-window recording. Once
    /// `traceFullPauseSeconds` have elapsed without the recording
    /// stopping (= marginal recording, needs more time), emissions
    /// resume so the user sees fresh data.
    private var traceFullTimestamp: ContinuousClock.Instant? = nil
    private let traceFullPauseSeconds: Double = 1.5

    // Band-selection cadence (slower than trace cadence).
    private var samplesSinceLastBandSelect: Int = 0
    private var samplesPerBandSelect: Int = 48000  // 1 s

    // Bar-update cadence (faster than band select so bars feel responsive).
    private var samplesSinceLastBarUpdate: Int = 0
    private var samplesPerBarUpdate: Int = 12000  // 0.25 s

    // Currently-active source for the trace and bars. Stored here (not in
    // SpectrogramData) so we can mutate from the analysis queue without
    // round-tripping through MainActor. Mirror is published to SpectrogramData
    // via `bestBandHz` for the UI label.
    //
    // Bins are kept for the band-selection scoring path (which iterates
    // over FFT bins). The center frequency in Hz is kept for the trace
    // and bar paths (which use a time-domain bandpass, not the FFT).
    private var currentBandLowBin: Int = -1
    private var currentBandHighBin: Int = -1
    private var currentBandCenterHz: Double = 18000.0

    /// Shared signal conditioner used by the bandpass-based trace and bar
    /// envelopes. Stateless struct; cheap to keep.
    private let conditioner = SignalConditioner()
    /// Rhythmicity score of the current band at the last band-selection
    /// scan. Used for hysteresis: only switch to a new candidate band
    /// when its score is meaningfully better (≥ 10 %) than what we have.
    private var currentBandScore: Double = 0
    /// Hysteresis margin — new band must score this multiple of the
    /// current band's score before we switch. 1.10 = 10 % better.
    private let bandSwitchMargin: Double = 1.10
    /// True once the first real band-selection scan has run. Until then
    /// the band is the "best guess" set in resetState (around 6 kHz) and
    /// the first scan switches without hysteresis. Prevents the initial
    /// cosmetic guess from "sticking" if it happens to score reasonably
    /// well against a slightly-better real band.
    private var hasFirstScanRun: Bool = false
    /// Center frequency of the initial "best guess" band. Empirically
    /// the picker most often lands in the 14–18 kHz range across the
    /// test corpus (NH35, Omega, Timex), so 18 kHz is a better seed
    /// than the original 6 kHz — the initial visual matches the real
    /// pick more often, and band-switch transitions are less jarring.
    private let initialBandCenterHz: Double = 18000.0
    private let bandHalfWidthHz: Double = 500.0

    private let analysisQueue = DispatchQueue(label: "SpectrogramMonitor.analysis")

    init(data: SpectrogramData) {
        self.data = data
        self.log2n = vDSP_Length(log2(Double(fftWindowSize)))
        var win = [Float](repeating: 0, count: fftWindowSize)
        vDSP_hann_window(&win, vDSP_Length(fftWindowSize), Int32(vDSP_HANN_NORM))
        self.hannWindow = win
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
    }

    func start() throws {
        configInfo = try AudioSessionConfigurator.configure()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        try? inputNode.setVoiceProcessingEnabled(false)
        let format = inputNode.outputFormat(forBus: 0)
        analysisQueue.sync { resetState(sampleRate: format.sampleRate) }

        inputNode.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, _ in
            guard let self = self, let dataPtr = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: dataPtr, count: count))
            self.analysisQueue.async {
                self.appendAndAnalyze(samples)
            }
        }

        try engine.start()
        self.engine = engine
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        analysisQueue.async {
            self.rollingBuffer = []
        }
    }

    func initializeForExternalFeed(sampleRate: Double) {
        analysisQueue.sync { resetState(sampleRate: sampleRate) }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        data.reset()
    }

    func feedSamples(_ samples: [Float]) {
        analysisQueue.async {
            self.appendAndAnalyze(samples)
        }
    }

    // MARK: - Internals

    private func resetState(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.rollingBufferSize = Int(rollingBufferDuration * sampleRate)
        self.rollingBuffer = [Float](repeating: 0, count: rollingBufferSize)
        self.samplesAccumulated = 0
        self.samplesSinceLastColumn = 0
        self.samplesSinceLastBandSelect = 0
        self.samplesSinceLastBarUpdate = 0
        self.samplesPerColumn = Int(sampleRate * SpectrogramData.traceDtSec)
        self.samplesPerBandSelect = Int(sampleRate * 1.0)
        self.samplesPerBarUpdate = Int(sampleRate * 0.25)

        // Seed with a "best guess" narrow band around 6 kHz so the trace
        // looks qualitatively like a real-watch trace from the start —
        // rather than the busy broadband-sum we'd otherwise show until
        // the first band-selection scan runs (~3 s in). The first scan
        // bypasses hysteresis (hasFirstScanRun = false) and switches to
        // whatever band actually scores highest.
        let binsPerHz = Double(fftWindowSize) / sampleRate
        let bandHalfBins = max(2, Int(bandHalfWidthHz * binsPerHz))
        let centerBin = Int(initialBandCenterHz * binsPerHz)
        self.currentBandLowBin = max(1, centerBin - bandHalfBins)
        self.currentBandHighBin = min(fftWindowSize / 2 - 1, centerBin + bandHalfBins)
        self.currentBandCenterHz = initialBandCenterHz
        self.currentBandScore = 0
        self.hasFirstScanRun = false
        self.traceFullTimestamp = nil

        // Publish the seed band to the UI so the band-Hz label shows
        // immediately rather than "Scanning…".
        Task { @MainActor in
            self.data.bestBandHz = self.initialBandCenterHz
        }
    }

    private func appendAndAnalyze(_ newSamples: [Float]) {
        let newCount = newSamples.count
        if rollingBufferSize == 0 { return }
        if newCount >= rollingBufferSize {
            rollingBuffer = Array(newSamples.suffix(rollingBufferSize))
        } else {
            let shift = rollingBufferSize - newCount
            rollingBuffer.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.update(from: buf.baseAddress! + newCount, count: shift)
            }
            rollingBuffer.replaceSubrange(shift..<rollingBufferSize, with: newSamples)
        }
        samplesAccumulated += newCount
        samplesSinceLastColumn += newCount
        samplesSinceLastBandSelect += newCount
        samplesSinceLastBarUpdate += newCount

        // Emit trace samples whenever enough audio has accumulated.
        while samplesSinceLastColumn >= samplesPerColumn {
            samplesSinceLastColumn -= samplesPerColumn
            guard samplesAccumulated >= fftWindowSize else { continue }

            // Pause emissions briefly once the trace buffer first hits
            // full so the trace doesn't visibly scroll during the
            // picker's analysis-decision time for a successful
            // first-window recording. Resume after traceFullPauseSeconds
            // if the recording is still going (marginal case — user
            // sees fresh data again).
            if data.totalTraceWritten >= SpectrogramData.traceSampleCount {
                if traceFullTimestamp == nil {
                    traceFullTimestamp = ContinuousClock.now
                }
                let pausedFor = (ContinuousClock.now - traceFullTimestamp!).asSeconds
                if pausedFor < traceFullPauseSeconds { continue }
            }
            emitTraceSample()
        }

        if samplesSinceLastBandSelect >= samplesPerBandSelect {
            samplesSinceLastBandSelect = 0
            updateBestBand()
        }
        if samplesSinceLastBarUpdate >= samplesPerBarUpdate {
            samplesSinceLastBarUpdate = 0
            updateBars()
        }
    }

    /// Emit one trace sample = mean band energy over the most recent
    /// `traceDtSec` of audio (50 ms). Uses a time-domain bandpass at the
    /// currently-selected band — no FFT, no coverage gap. Each tick of
    /// the watch shows up as a brief energy spike.
    ///
    /// We process more than one block at a time (`lookbackSec`) so the
    /// IIR filter's startup transient (~1 ms for a 1 kHz-wide passband)
    /// is in the discarded prefix, and the returned last sample is fully
    /// settled.
    private func emitTraceSample() {
        let targetRateHz = 1.0 / SpectrogramData.traceDtSec   // 20 Hz
        let lookbackSec = 0.2   // 200 ms → 4 output blocks; last is settled
        let lookbackSamples = min(rollingBuffer.count,
                                  Int(lookbackSec * sampleRate))
        guard lookbackSamples >= Int(sampleRate / targetRateHz) else { return }
        let start = rollingBuffer.count - lookbackSamples
        let block = Array(rollingBuffer[start..<rollingBuffer.count])

        let env = conditioner.bandpassEnergyEnvelope(
            samples: block,
            sampleRate: sampleRate,
            centerHz: currentBandCenterHz,
            halfWidthHz: bandHalfWidthHz,
            targetRateHz: targetRateHz
        )
        guard let sample = env.last else { return }
        data.appendTraceSample(sample)
    }

    /// Look for a narrow frequency band whose energy time-series shows
    /// the strongest rhythmic modulation at a standard mechanical beat
    /// rate. If one beats broadband by a margin, switch the trace
    /// source to it.
    private func updateBestBand() {
        // Need enough audio history. With ~20 trace samples/sec, 60
        // samples = 3 s — enough for Goertzel to distinguish 5/5.5/6 Hz.
        let totalCols = data.totalTraceWritten
        guard totalCols >= 60 else { return }

        // We need column-by-column STFT slices to score per-bin
        // rhythmicity. Compute them from the rolling raw buffer.
        // For efficiency, only re-do this once per second (we're inside
        // that gate already).
        let analyzeWindowSeconds = min(15.0, Double(totalCols) * SpectrogramData.traceDtSec)
        let analyzeSampleCount = Int(analyzeWindowSeconds * sampleRate)
        guard rollingBuffer.count >= analyzeSampleCount else { return }
        let start = rollingBuffer.count - analyzeSampleCount
        let snapshot = Array(rollingBuffer[start..<rollingBuffer.count])

        // Build per-bin time series via STFT (50 ms hop, 1024-pt window).
        let nBins = fftWindowSize / 2
        let hop = samplesPerColumn
        let nFrames = max(1, (analyzeSampleCount - fftWindowSize) / hop + 1)

        var perBin = [[Float]](repeating: [Float](repeating: 0, count: nFrames), count: nBins)
        guard let setup = fftSetup else { return }
        var seg = [Float](repeating: 0, count: fftWindowSize)
        var realPart = [Float](repeating: 0, count: nBins)
        var imagPart = [Float](repeating: 0, count: nBins)

        for t in 0..<nFrames {
            let startIdx = t * hop
            for i in 0..<fftWindowSize {
                seg[i] = snapshot[startIdx + i] * hannWindow[i]
            }
            for i in 0..<nBins {
                realPart[i] = seg[2 * i]
                imagPart[i] = seg[2 * i + 1]
            }
            realPart.withUnsafeMutableBufferPointer { rp in
                imagPart.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            for k in 0..<nBins {
                let re = realPart[k]
                let im = imagPart[k]
                perBin[k][t] = sqrt(re * re + im * im)
            }
        }

        // Score each bin in 4-22 kHz. Track the overall winner AND the
        // best score within the currently-selected band so we can compare
        // them like-for-like for hysteresis (otherwise we'd compare a
        // fresh score against a stale one).
        let beatHz: [Double] = [5.0, 5.5, 6.0, 7.0, 8.0, 10.0]
        let frameRate = sampleRate / Double(hop)
        let binsPerHz = Double(fftWindowSize) / sampleRate
        let firstBin = max(1, Int(4000.0 * binsPerHz))
        let lastBin = min(nBins - 1, Int(22000.0 * binsPerHz))

        var bestBin = -1
        var bestScore: Double = 0
        var currentBandBestScore: Double = 0
        for k in firstBin...lastBin {
            var series = perBin[k]
            var mean: Float = 0
            vDSP_meanv(series, 1, &mean, vDSP_Length(nFrames))
            var negMean = -mean
            vDSP_vsadd(series, 1, &negMean, &series, 1, vDSP_Length(nFrames))

            var peak: Double = 0
            for r in beatHz {
                let mag = goertzelMagnitude(series: series, frameRate: frameRate, targetHz: r)
                if mag > peak { peak = mag }
            }
            var bgMags: [Double] = []
            var f = 3.0
            while f <= 12.0 {
                var near = false
                for r in beatHz where abs(f - r) < 0.5 { near = true; break }
                if !near {
                    bgMags.append(goertzelMagnitude(series: series, frameRate: frameRate, targetHz: f))
                }
                f += 0.25
            }
            guard !bgMags.isEmpty else { continue }
            bgMags.sort()
            let median = bgMags[bgMags.count / 2]
            let score = peak / max(median, 1e-12)
            if score > bestScore {
                bestScore = score
                bestBin = k
            }
            // Track current-band's best for the hysteresis comparison.
            if currentBandLowBin >= 0 && k >= currentBandLowBin && k <= currentBandHighBin {
                if score > currentBandBestScore { currentBandBestScore = score }
            }
        }

        // Require the best narrow band to clearly beat the noise floor
        // before adopting it.
        guard bestBin >= 0, bestScore >= 3.0 else { return }

        // Hysteresis applies once we've completed at least one real
        // scan. The very first scan after a fresh resetState ignores
        // hysteresis so the cosmetic "best guess" seed band (~6 kHz)
        // doesn't stick if a meaningfully better band exists. After
        // that, switching requires bandSwitchMargin (10%) improvement
        // over the current band's score on this scan.
        let bandHalfBins = max(2, Int(bandHalfWidthHz * binsPerHz))
        let candidateLow = max(firstBin, bestBin - bandHalfBins)
        let candidateHigh = min(lastBin, bestBin + bandHalfBins)
        if hasFirstScanRun && currentBandLowBin >= 0 {
            let withinCurrent = (bestBin >= currentBandLowBin && bestBin <= currentBandHighBin)
            if withinCurrent {
                currentBandScore = currentBandBestScore
                return
            }
            if bestScore < currentBandBestScore * bandSwitchMargin {
                currentBandScore = currentBandBestScore
                return
            }
        }
        hasFirstScanRun = true

        // Switching (or first lock). Update band + score.
        currentBandLowBin = candidateLow
        currentBandHighBin = candidateHigh
        currentBandScore = bestScore
        let bestHz = (Double(bestBin) + 0.5) * sampleRate / Double(fftWindowSize)
        currentBandCenterHz = bestHz

        // Rebuild the visible trace by re-running the new band's bandpass
        // energy envelope over the same audio snapshot. The existing trace
        // buffer holds samples computed under the OLD band; without this
        // rebuild the user would see a discontinuity midway through the
        // trace. With it, the entire visible trace updates to a consistent
        // re-interpretation of the last 15 s of audio through the newly
        // chosen band.
        let traceRate = 1.0 / SpectrogramData.traceDtSec
        let newTrace = conditioner.bandpassEnergyEnvelope(
            samples: snapshot,
            sampleRate: sampleRate,
            centerHz: bestHz,
            halfWidthHz: bandHalfWidthHz,
            targetRateHz: traceRate
        )

        Task { @MainActor in
            self.data.bestBandHz = bestHz
            self.data.replaceTrace(with: newTrace)
        }
    }

    /// Window length (seconds) of envelope used for the bar Goertzel.
    /// 5 s gives 0.2 Hz Goertzel resolution — comfortable margin over
    /// the 0.5 Hz spacing between adjacent standard rates (5 / 5.5 Hz).
    private let barAnalysisWindowSec: Double = 5.0

    /// Sample rate (Hz) of the envelope fed into the bar Goertzel.
    /// 100 Hz gives Nyquist 50 Hz — clears the first several harmonics
    /// of every standard beat rate so they don't fold onto neighbouring
    /// standard bars. (At the 20 Hz trace rate, a 6 Hz tick's 12 Hz
    /// second harmonic aliases to 8 Hz, inflating the 28800 bph bar to
    /// nearly the height of the real 21600 bph bar on NH35 recordings —
    /// the original aliasing bug that motivated this separate channel.)
    private let barEnvelopeRateHz: Double = 100.0

    /// Compute Goertzel magnitudes at each standard beat rate against a
    /// freshly-built 100 Hz band-energy envelope over the most recent
    /// `barAnalysisWindowSec` of audio. Normalize so the strongest rate
    /// is 1.0 and publish for the bar display.
    ///
    /// Shares `SignalConditioner.bandpassEnergyEnvelope` with the trace
    /// (which uses a 20 Hz target rate). Same bandpass, same rectifier,
    /// same band-center — only the time resolution differs.
    private func updateBars() {
        // Need at least 2 s of audio to distinguish 5 / 5.5 Hz reliably.
        // Use the full 5-s window once we have it; ramp up gracefully
        // during the first few seconds.
        let minBarWindowSec = 2.0
        let minSamples = Int(minBarWindowSec * sampleRate)
        guard samplesAccumulated >= minSamples,
              rollingBuffer.count >= minSamples else {
            Task { @MainActor in self.data.rateMagnitudes = [:] }
            return
        }
        let targetWindowSamples = Int(barAnalysisWindowSec * sampleRate)
        let envWindowSamples = min(targetWindowSamples,
                                   min(samplesAccumulated, rollingBuffer.count))
        let start = rollingBuffer.count - envWindowSamples
        let block = Array(rollingBuffer[start..<rollingBuffer.count])

        var envelope = conditioner.bandpassEnergyEnvelope(
            samples: block,
            sampleRate: sampleRate,
            centerHz: currentBandCenterHz,
            halfWidthHz: bandHalfWidthHz,
            targetRateHz: barEnvelopeRateHz
        )
        let barFrameRate = barEnvelopeRateHz
        let n = envelope.count
        guard n >= 2 else {
            Task { @MainActor in self.data.rateMagnitudes = [:] }
            return
        }

        // Detrend.
        var mean: Float = 0
        vDSP_meanv(envelope, 1, &mean, vDSP_Length(n))
        var negMean = -mean
        vDSP_vsadd(envelope, 1, &negMean, &envelope, 1, vDSP_Length(n))

        var raw: [StandardBeatRate: Float] = [:]
        var maxMag: Float = 0
        for rate in StandardBeatRate.allCases {
            let mag = Float(goertzelMagnitude(series: envelope, frameRate: barFrameRate, targetHz: rate.hz))
            raw[rate] = mag
            if mag > maxMag { maxMag = mag }
        }
        // Normalize to [0, 1]; strongest rate = 1.
        var normalized: [StandardBeatRate: Float] = [:]
        if maxMag > 0 {
            for (k, v) in raw { normalized[k] = v / maxMag }
        } else {
            normalized = raw
        }
        data.publishRateMagnitudes(normalized)
    }

    private func goertzelMagnitude(series: [Float], frameRate: Double, targetHz: Double) -> Double {
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
}
