import AVFoundation
import Accelerate
import WatchBeatCore

/// Real-time spectrogram producer for the Monitoring/Recording UI.
///
/// Mirrors the lifecycle of FrequencyMonitor (start/stop, internal
/// AVAudioEngine for monitoring, external sample feed for recording),
/// but produces STFT columns rather than per-rate FFT magnitudes.
///
/// Each column is one short-time FFT over the most recent ~21 ms of
/// audio. Columns are emitted every 50 ms so the visible 15-second
/// window contains exactly 300 columns. Each column's magnitudes are
/// log-scaled and normalized to [0, 1] for display.
///
/// Also performs band-selection (echoing what MultibandSelector does in
/// the picker pipeline) so the UI can show the algorithm's current
/// best-band guess as a red horizontal line — visualizing the same
/// rhythmic-band detection the picker uses.
final class SpectrogramMonitor: @unchecked Sendable {

    /// The data source the UI binds to.
    let data: SpectrogramData

    private var engine: AVAudioEngine?
    private(set) var configInfo: String = ""

    // FFT setup
    private let fftWindowSize = 1024
    private let log2n: vDSP_Length
    private let hannWindow: [Float]
    private let fftSetup: FFTSetup?
    private var sampleRate: Double = 48000

    // Rolling raw audio buffer — keeps the most recent ~25 s so that
    // we always have enough samples for a 1024-pt FFT plus headroom
    // for band-scoring.
    private let rollingBufferDuration: Double = 16.0
    private var rollingBuffer: [Float] = []
    private var rollingBufferSize: Int = 0
    private var samplesAccumulated: Int = 0

    // Column emit cadence
    private var samplesSinceLastColumn: Int = 0
    private var samplesPerColumn: Int = 2400  // 50 ms at 48 kHz

    // Band-selection cadence (slower than column cadence — band changes
    // slowly relative to display refresh)
    private var samplesSinceLastBandSelect: Int = 0
    private var samplesPerBandSelect: Int = 48000  // 1 s at 48 kHz

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

    /// Switch to external-feed mode (used during recording, when audio
    /// is captured by AudioCaptureService and fed in here). Resets all
    /// state so previous columns don't bleed into the new session.
    func initializeForExternalFeed(sampleRate: Double) {
        analysisQueue.sync { resetState(sampleRate: sampleRate) }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        data.reset()
    }

    /// Feed externally-captured samples (called by the recording loop).
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
        self.samplesPerColumn = Int(sampleRate * SpectrogramData.columnDtSec)
        self.samplesPerBandSelect = Int(sampleRate * 1.0)
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

        // Emit a column whenever enough samples have arrived. Loop so
        // a large incoming buffer can emit multiple columns to keep up.
        while samplesSinceLastColumn >= samplesPerColumn {
            samplesSinceLastColumn -= samplesPerColumn
            if samplesAccumulated >= fftWindowSize {
                emitColumn()
            }
        }

        // Periodic band-selection updates.
        if samplesSinceLastBandSelect >= samplesPerBandSelect {
            samplesSinceLastBandSelect = 0
            updateBestBand()
        }
    }

    /// Compute one STFT column from the most-recent fftWindowSize samples
    /// and append it to the rolling spectrogram. Magnitudes are mapped
    /// into the 4-22 kHz display range and log-scaled so dim peaks are
    /// visible alongside loud ones.
    private func emitColumn() {
        guard let setup = fftSetup else { return }
        let n = fftWindowSize
        var seg = [Float](repeating: 0, count: n)
        let tail = rollingBuffer.suffix(n)
        for (i, v) in tail.enumerated() { seg[i] = v }
        vDSP_vmul(seg, 1, hannWindow, 1, &seg, 1, vDSP_Length(n))

        var realPart = [Float](repeating: 0, count: n / 2)
        var imagPart = [Float](repeating: 0, count: n / 2)
        for i in 0..<(n / 2) {
            realPart[i] = seg[2 * i]
            imagPart[i] = seg[2 * i + 1]
        }
        var magnitudes = [Float](repeating: 0, count: n / 2)
        realPart.withUnsafeMutableBufferPointer { rp in
            imagPart.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        var sqrtMag = [Float](repeating: 0, count: n / 2)
        var count32 = Int32(n / 2)
        vvsqrtf(&sqrtMag, magnitudes, &count32)

        // Map into the display freq range. Bin k corresponds to k*sr/n Hz.
        let binsPerHz = Double(n) / sampleRate
        let firstBin = max(1, Int(SpectrogramData.minFreqHz * binsPerHz))
        let lastBin = min(n / 2 - 1, Int(SpectrogramData.maxFreqHz * binsPerHz))
        let outBins = SpectrogramData.binCount
        var column = [Float](repeating: 0, count: outBins)
        // For each output bin, find the corresponding FFT bin range and
        // take the max — preserves narrowband features even when display
        // resolution is lower than FFT resolution.
        for k in 0..<outBins {
            let frac0 = Double(k) / Double(outBins)
            let frac1 = Double(k + 1) / Double(outBins)
            let b0 = firstBin + Int(frac0 * Double(lastBin - firstBin))
            let b1 = firstBin + Int(frac1 * Double(lastBin - firstBin))
            let lo = max(0, b0)
            let hi = min(n / 2 - 1, max(b0, b1 - 1))
            var m: Float = 0
            for bi in lo...hi { if sqrtMag[bi] > m { m = sqrtMag[bi] } }
            column[k] = m
        }

        // Log-scale and normalize against a slowly-tracked headroom so
        // dim recordings look bright enough to see and loud ones don't
        // saturate. Empirical floor/ceiling: -90 dB to 0 dB.
        var maxMag: Float = 0
        for v in column { if v > maxMag { maxMag = v } }
        let floor: Float = -60
        let displayCeiling: Float = 20 * log10f(max(maxMag, 1e-6))
        let range = max(20, displayCeiling - floor)
        for k in 0..<outBins {
            let db = 20 * log10f(max(column[k], 1e-6))
            let v = max(0, min(1, (db - floor) / range))
            column[k] = v
        }
        data.appendColumn(column)
    }

    /// Score each frequency bin's rhythmicity and pick the best — same
    /// scoring as MultibandSelector but uses our STFT columns so we
    /// don't need a separate analysis pass. Updates the red line on
    /// the UI; doesn't influence picker behavior.
    private func updateBestBand() {
        // Need at least ~3 seconds of columns for meaningful rhythm
        // FFT (3 s × 20 Hz column rate = 60 columns).
        let minColumnsForBandSelect = 60
        let totalCols = data.totalColumnsWritten
        guard totalCols >= minColumnsForBandSelect else { return }

        // Get the most recent N columns directly (snapshot the data's
        // current state). We read on main, so dispatch to compute.
        let snapshotColumns = data.columns
        let writeIdx = data.writeIndex
        let nColumns = SpectrogramData.columnCount

        // Build per-bin time series for the visible window. The buffer
        // is circular — start at writeIdx (oldest column) and read
        // forward.
        let nBins = SpectrogramData.binCount
        let frameRate = 1.0 / SpectrogramData.columnDtSec  // 20 Hz

        // Mechanical beat rates
        let beatHz: [Double] = [5.0, 5.5, 6.0, 7.0, 8.0, 10.0]
        let availCols = min(totalCols, nColumns)
        let startCol = totalCols < nColumns ? 0 : writeIdx

        var bestBin = -1
        var bestScore: Double = 0
        for k in 0..<nBins {
            // Extract this bin's time series.
            var series = [Float](repeating: 0, count: availCols)
            for t in 0..<availCols {
                let col = (startCol + t) % nColumns
                series[t] = snapshotColumns[col][k]
            }
            // Subtract mean (DC removal).
            var mean: Float = 0
            vDSP_meanv(series, 1, &mean, vDSP_Length(availCols))
            var negMean = -mean
            vDSP_vsadd(series, 1, &negMean, &series, 1, vDSP_Length(availCols))

            // Goertzel at each standard beat rate; take the peak.
            var peak: Double = 0
            for r in beatHz {
                let mag = goertzelMagnitude(series: series, frameRate: frameRate, targetHz: r)
                if mag > peak { peak = mag }
            }
            // Off-rate baseline — median magnitude at non-mechanical freqs.
            var bgMags: [Double] = []
            var f = 3.0
            while f <= 12.0 {
                var nearStandard = false
                for r in beatHz where abs(f - r) < 0.5 { nearStandard = true; break }
                if !nearStandard {
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
        }

        guard bestBin >= 0, bestScore >= 3.0 else {
            // Don't display a "best band" unless there's something
            // meaningfully better than the floor.
            return
        }
        let freqRange = SpectrogramData.maxFreqHz - SpectrogramData.minFreqHz
        let bestHz = SpectrogramData.minFreqHz + (Double(bestBin) + 0.5) / Double(nBins) * freqRange
        Task { @MainActor in
            self.data.bestBandHz = bestHz
        }
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
