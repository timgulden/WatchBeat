import AVFoundation
import Accelerate
import WatchBeatCore

/// Real-time frequency monitor that shows envelope FFT power at each standard beat rate.
/// Maintains a rolling buffer of audio, computes the envelope, FFTs it, and publishes
/// the magnitude at each of the 7 candidate frequencies — like a graphic equalizer
/// tuned to watch beat rates.
final class FrequencyMonitor: @unchecked Sendable {

    /// Power at each standard beat rate, updated ~4x/sec.
    @MainActor var ratePowers: [StandardBeatRate: Float] = [:]
    /// Peak raw amplitude for reference.
    @MainActor var rawPeak: Float = 0

    private var engine: AVAudioEngine?
    private(set) var configInfo: String = ""
    private let conditioner = SignalConditioner()

    deinit {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
    }

    // Rolling buffer: ~5 seconds of audio at 48 kHz for decent frequency resolution
    private let rollingBufferDuration: Double = 5.0
    private var rollingBuffer: [Float] = []
    private var rollingBufferSize: Int = 0
    private var sampleRate: Double = 48000
    private let analysisQueue = DispatchQueue(label: "FrequencyMonitor.analysis")

    func start() throws {
        configInfo = try AudioSessionConfigurator.configure()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        try? inputNode.setVoiceProcessingEnabled(false)
        let format = inputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        rollingBufferSize = Int(rollingBufferDuration * sampleRate)
        rollingBuffer = [Float](repeating: 0, count: rollingBufferSize)

        // Use a larger buffer for less overhead
        inputNode.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, _ in
            guard let self = self, let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: data, count: count))

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
        rollingBuffer = []
    }

    /// Switch to external feed mode, preserving the existing buffer so there's
    /// no gap in the frequency bars when transitioning from listening to recording.
    func initializeForExternalFeed(sampleRate: Double) {
        // Only reset if sample rate changed or buffer not yet initialized
        if self.sampleRate != sampleRate || rollingBuffer.isEmpty {
            self.sampleRate = sampleRate
            rollingBufferSize = Int(rollingBufferDuration * sampleRate)
            rollingBuffer = [Float](repeating: 0, count: rollingBufferSize)
            samplesAccumulated = 0
        }
        // Stop the engine (external source will call feedSamples) but keep the buffer
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        analysisCooldown = 0
    }

    func feedSamples(_ samples: [Float]) {
        analysisQueue.async {
            self.appendAndAnalyze(samples)
        }
    }

    // MARK: - Analysis

    private var samplesAccumulated: Int = 0
    private var analysisCooldown: Int = 0

    private func appendAndAnalyze(_ newSamples: [Float]) {
        // Shift rolling buffer left and append new samples
        let newCount = newSamples.count
        if newCount >= rollingBufferSize {
            // New samples fill the entire buffer
            rollingBuffer = Array(newSamples.suffix(rollingBufferSize))
        } else {
            // Shift left
            let shift = rollingBufferSize - newCount
            rollingBuffer.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.update(from: buf.baseAddress! + newCount, count: shift)
            }
            rollingBuffer.replaceSubrange(shift..<rollingBufferSize, with: newSamples)
        }

        samplesAccumulated += newCount

        // Analyze ~4 times per second (every ~12000 samples at 48 kHz)
        analysisCooldown += newCount
        let analysisInterval = Int(sampleRate / 4.0)
        guard analysisCooldown >= analysisInterval else { return }
        analysisCooldown = 0

        // Don't analyze until we have a full buffer
        guard samplesAccumulated >= rollingBufferSize else { return }

        // Raw peak (on unfiltered buffer, for mic-level diagnostic)
        var peak: Float = 0
        vDSP_maxv(rollingBuffer, 1, &peak, vDSP_Length(rollingBufferSize))
        var negPeak: Float = 0
        vDSP_minv(rollingBuffer, 1, &negPeak, vDSP_Length(rollingBufferSize))
        let rawPeakVal = max(peak, -negPeak)

        // Highpass filter to match the main pipeline — removes rumble/hum that
        // would otherwise bias the envelope FFT's rate scores.
        let filtered = conditioner.highpassFilter(
            rollingBuffer,
            sampleRate: sampleRate,
            cutoff: MeasurementPipeline.highpassCutoffHz
        )

        // Compute envelope: rectify + lowpass (moving average) + decimate
        var rectified = [Float](repeating: 0, count: rollingBufferSize)
        vDSP_vabs(filtered, 1, &rectified, 1, vDSP_Length(rollingBufferSize))

        let avgWindow = max(3, Int(sampleRate / 100.0)) // ~100 Hz lowpass
        let smoothedCount = rollingBufferSize - avgWindow + 1
        guard smoothedCount > 100 else { return }

        var smoothed = [Float](repeating: 0, count: smoothedCount)
        var runSum: Float = 0
        for i in 0..<avgWindow { runSum += rectified[i] }
        smoothed[0] = runSum / Float(avgWindow)
        for i in 1..<smoothedCount {
            runSum += rectified[i + avgWindow - 1] - rectified[i - 1]
            smoothed[i] = runSum / Float(avgWindow)
        }

        // Decimate to ~1 kHz
        let decimFactor = max(1, Int(sampleRate / 1000.0))
        let decimCount = smoothedCount / decimFactor
        guard decimCount > 50 else { return }

        var decimated = [Float](repeating: 0, count: decimCount)
        for i in 0..<decimCount {
            decimated[i] = smoothed[i * decimFactor]
        }
        let envRate = sampleRate / Double(decimFactor)

        // FFT of envelope
        let fftLength = nextPowerOfTwo(decimCount)
        let magnitudes = computeFFTMagnitudes(samples: decimated, fftLength: fftLength)
        let freqRes = envRate / Double(fftLength)

        // Measure power at each standard rate.
        // Window is ±0.2 Hz — narrow enough to avoid overlap between adjacent
        // beat rates (closest pair is 5.0 and 5.5 Hz, 0.5 Hz apart).
        var powers: [StandardBeatRate: Float] = [:]
        for rate in StandardBeatRate.allCases {
            let targetBin = Int(round(rate.hz / freqRes))
            let windowRadius = max(1, Int(ceil(0.2 / freqRes)))
            let lo = max(0, targetBin - windowRadius)
            let hi = min(magnitudes.count - 1, targetBin + windowRadius)
            var peak: Float = 0
            for bin in lo...hi {
                peak = max(peak, magnitudes[bin])
            }
            powers[rate] = peak
        }

        Task { @MainActor [powers, rawPeakVal] in
            self.ratePowers = powers
            self.rawPeak = rawPeakVal
        }
    }

    // MARK: - FFT

    private func computeFFTMagnitudes(samples: [Float], fftLength: Int) -> [Float] {
        let n = samples.count
        var windowed = [Float](repeating: 0, count: n)
        var hannWindow = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hannWindow, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, hannWindow, 1, &windowed, 1, vDSP_Length(n))

        var padded = [Float](repeating: 0, count: fftLength)
        padded.replaceSubrange(0..<n, with: windowed)

        let log2n = vDSP_Length(log2(Double(fftLength)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = fftLength / 2
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)

        padded.withUnsafeBufferPointer { buf in
            for i in 0..<halfN {
                realPart[i] = buf[2 * i]
                imagPart[i] = buf[2 * i + 1]
            }
        }

        var magnitudes = [Float](repeating: 0, count: halfN)
        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        var sqrtMag = [Float](repeating: 0, count: halfN)
        var count32 = Int32(halfN)
        vvsqrtf(&sqrtMag, magnitudes, &count32)
        return sqrtMag
    }

    private func nextPowerOfTwo(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16
        return v + 1
    }
}
