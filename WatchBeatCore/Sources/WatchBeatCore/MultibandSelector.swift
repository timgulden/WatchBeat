import Foundation
import Accelerate

/// Spectrogram-based narrow-band selector for tick signal extraction.
///
/// The Reference picker's default 5 kHz highpass passes all energy above
/// 5 kHz equally, which loses SNR when noise lives in a different spectral
/// region from the watch's tick energy. This selector computes a short-
/// time Fourier transform (STFT) of the raw signal, then for each
/// frequency bin asks "does this band's energy oscillate at a standard
/// mechanical beat rate?" The band with the strongest rhythmic peak vs
/// its baseline magnitude wins.
///
/// Math, briefly:
///   1. STFT(x[n]) → spectrogram |X[k, t]| at frequency bin k, frame t.
///   2. For each k, take the time series e_k[t] = |X[k, t]|.
///   3. FFT of e_k[t] at standard mechanical rates (5, 5.5, 6, 7, 8,
///      10 Hz) gives the strength of rhythmic modulation at those rates.
///   4. score(k) = max_rate(magnitude) / median(magnitudes) — high when
///      the band's energy is strongly modulated at a beat rate vs flat
///      background.
///   5. Pick argmax_k(score(k)); return the band's frequency range.
///
/// Cost: one STFT pass + per-bin Goertzel at 6 rates ≈ 2-5 ms on iPhone
/// for a 15 s recording, well under user-perceivable latency.
enum MultibandSelector {

    /// Result of band selection: the chosen frequency range, the
    /// rhythmicity score it achieved, and the score the standard broadband
    /// (5 kHz highpass) baseline would have achieved. Caller decides
    /// whether the narrow band is sufficiently better than the baseline
    /// to use it.
    struct Selection {
        let lowHz: Double
        let highHz: Double
        let score: Double
        let baselineScore: Double
        let bestBinCenterHz: Double
    }

    /// Standard mechanical beat rates (Hz). Includes 36000 bph (10 Hz) at
    /// the top and 18000 bph (5 Hz) at the bottom.
    private static let standardBeatHzs: [Double] = [5.0, 5.5, 6.0, 7.0, 8.0, 10.0]

    /// Select the best narrow band for tick detection. Returns nil if the
    /// best narrow band does not beat the broadband baseline by the
    /// configured margin — in which case the caller should fall back to
    /// the standard 5 kHz highpass pipeline.
    ///
    /// - Parameters:
    ///   - samples: raw audio samples.
    ///   - sampleRate: audio sample rate (Hz).
    ///   - minWinHz: low end of the search range (Hz). Bins below this
    ///     are not considered (mic rumble, voice, HVAC live below this).
    ///   - maxWinHz: high end of the search range. Bins above this are
    ///     typically below the mic's response or contain only quantization
    ///     noise.
    ///   - margin: required ratio of best-band score to baseline score
    ///     for the narrow band to be selected. 1.0 = always pick narrow;
    ///     2.0 = require 2× improvement. Default 1.5×.
    ///   - bandHalfWidthHz: half-width (in Hz) of the bandpass to return
    ///     around the winning bin's center frequency. Default 500 Hz so
    ///     the returned range is 1 kHz wide.
    static func selectBestBand(
        samples: [Float],
        sampleRate: Double,
        minWinHz: Double = 5000.0,
        maxWinHz: Double = 22000.0,
        margin: Double = 1.5,
        bandHalfWidthHz: Double = 500.0
    ) -> Selection? {
        let stft = computeSTFT(samples: samples, sampleRate: sampleRate)
        guard !stft.bins.isEmpty, !stft.frames.isEmpty else { return nil }

        let frameRate = sampleRate / Double(stft.hop)
        let nFrames = stft.frames.count

        // For each frequency bin in the search range, compute its
        // rhythmicity score: max magnitude (Goertzel) at any standard
        // beat rate / median magnitude across a sweep of nearby rate
        // bins (the local baseline).
        var bestBin = -1
        var bestScore = 0.0
        let nBins = stft.bins[0].count
        for k in 0..<nBins {
            let fHz = Double(k) * sampleRate / Double(stft.winSize)
            if fHz < minWinHz || fHz > maxWinHz { continue }
            // Time series of magnitudes for bin k.
            var series = [Float](repeating: 0, count: nFrames)
            for t in 0..<nFrames {
                series[t] = stft.bins[t][k]
            }
            // Remove DC so the rhythm FFT doesn't see the mean.
            var mean: Float = 0
            vDSP_meanv(series, 1, &mean, vDSP_Length(nFrames))
            var negMean = -mean
            vDSP_vsadd(series, 1, &negMean, &series, 1, vDSP_Length(nFrames))
            let score = rhythmicityScore(series: series, frameRate: frameRate)
            if score > bestScore {
                bestScore = score
                bestBin = k
            }
        }
        guard bestBin >= 0 else { return nil }

        // Baseline: score the broadband (all bins summed) the same way.
        var broadband = [Float](repeating: 0, count: nFrames)
        for t in 0..<nFrames {
            var sum: Float = 0
            for k in 0..<nBins {
                let fHz = Double(k) * sampleRate / Double(stft.winSize)
                if fHz < minWinHz || fHz > maxWinHz { continue }
                sum += stft.bins[t][k]
            }
            broadband[t] = sum
        }
        var bbMean: Float = 0
        vDSP_meanv(broadband, 1, &bbMean, vDSP_Length(nFrames))
        var negBb = -bbMean
        vDSP_vsadd(broadband, 1, &negBb, &broadband, 1, vDSP_Length(nFrames))
        let baselineScore = rhythmicityScore(series: broadband, frameRate: frameRate)

        let bestFreqHz = Double(bestBin) * sampleRate / Double(stft.winSize)
        let lowHz = max(minWinHz, bestFreqHz - bandHalfWidthHz)
        let highHz = min(maxWinHz, bestFreqHz + bandHalfWidthHz)

        if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_MULTIBAND"] != nil {
            FileHandle.standardError.write(
                "[multiband] best=\(Int(bestFreqHz))Hz score=\(String(format: "%.2f", bestScore))  baseline=\(String(format: "%.2f", baselineScore))  ratio=\(String(format: "%.2f", bestScore / max(baselineScore, 1e-6)))×  margin=\(margin)×\n"
                .data(using: .utf8)!)
        }

        guard bestScore >= margin * baselineScore else { return nil }
        return Selection(
            lowHz: lowHz, highHz: highHz,
            score: bestScore, baselineScore: baselineScore,
            bestBinCenterHz: bestFreqHz
        )
    }

    // MARK: - STFT

    private struct STFTResult {
        let bins: [[Float]]    // bins[t][k] = magnitude of bin k at frame t
        let frames: [Int]      // start sample of each frame
        let winSize: Int
        let hop: Int
    }

    /// Short-time Fourier transform of the input signal.
    ///
    /// Window: Hann, length 256 (≈ 5.3 ms at 48 kHz). Hop: 64 samples
    /// (≈ 1.3 ms). Frequency resolution per bin: sr / 256 ≈ 188 Hz at
    /// 48 kHz. Time resolution per frame: 1.3 ms.
    ///
    /// Returns magnitudes (not power) so the per-bin time series is
    /// linear in amplitude — gives a slightly less peaked rhythm FFT
    /// than power but matches the linear time-series intuition.
    private static func computeSTFT(
        samples: [Float],
        sampleRate: Double,
        winSize: Int = 256,
        hop: Int = 64
    ) -> STFTResult {
        let n = samples.count
        guard n >= winSize else { return STFTResult(bins: [], frames: [], winSize: winSize, hop: hop) }
        let nFrames = (n - winSize) / hop + 1
        let nBins = winSize / 2 + 1

        // Hann window
        var window = [Float](repeating: 0, count: winSize)
        vDSP_hann_window(&window, vDSP_Length(winSize), Int32(vDSP_HANN_NORM))

        // FFT setup
        let log2n = vDSP_Length(log2(Double(winSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return STFTResult(bins: [], frames: [], winSize: winSize, hop: hop)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var bins = [[Float]](repeating: [Float](repeating: 0, count: nBins), count: nFrames)
        var frames = [Int](repeating: 0, count: nFrames)

        var seg = [Float](repeating: 0, count: winSize)
        var realPart = [Float](repeating: 0, count: winSize / 2)
        var imagPart = [Float](repeating: 0, count: winSize / 2)

        for t in 0..<nFrames {
            let start = t * hop
            frames[t] = start
            // Windowed segment
            samples.withUnsafeBufferPointer { sp in
                vDSP_vmul(sp.baseAddress! + start, 1, window, 1, &seg, 1, vDSP_Length(winSize))
            }
            // Split-complex packing: real[i] = seg[2i], imag[i] = seg[2i+1]
            for i in 0..<(winSize / 2) {
                realPart[i] = seg[2 * i]
                imagPart[i] = seg[2 * i + 1]
            }
            realPart.withUnsafeMutableBufferPointer { rb in
                imagPart.withUnsafeMutableBufferPointer { ib in
                    var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            // Magnitudes — for the zrip output, bins[0..<winSize/2-1] have
            // (real, imag) packed at (realPart[k], imagPart[k]); the
            // Nyquist bin lives in imagPart[0]. For our purposes (search
            // only in 5-22 kHz, well below Nyquist of 24 kHz), we can
            // ignore the unpacking subtlety and just compute magnitudes
            // for indices 1..<winSize/2. Index 0 holds DC (we skip it),
            // and Nyquist (index winSize/2) is rare for our search range.
            bins[t][0] = abs(realPart[0])  // DC
            for k in 1..<(winSize / 2) {
                let re = realPart[k]
                let im = imagPart[k]
                bins[t][k] = sqrt(re * re + im * im)
            }
            // Nyquist bin (winSize/2) — packed in imagPart[0]; we set it
            // to 0 (rarely in our search range and avoids confusion).
            bins[t][winSize / 2] = 0
        }
        return STFTResult(bins: bins, frames: frames, winSize: winSize, hop: hop)
    }

    // MARK: - Rhythmicity scoring

    /// Compute the rhythmicity score for one band's time series. Uses
    /// Goertzel evaluations at each standard mechanical beat rate (cheap,
    /// O(N) per rate) and divides the peak by the median of a sweep of
    /// frequencies in the same range (the local baseline).
    private static func rhythmicityScore(series: [Float], frameRate: Double) -> Double {
        let n = series.count
        guard n >= 32 else { return 0 }
        var peak: Double = 0
        for r in standardBeatHzs {
            let mag = goertzelMagnitude(series: series, frameRate: frameRate, targetHz: r)
            if mag > peak { peak = mag }
        }
        // Baseline: median magnitude across a sweep of "off-rate"
        // frequencies in the 3-12 Hz range (covers all standard rates
        // plus margin). We sweep at 0.25 Hz steps but EXCLUDE bins
        // within 0.5 Hz of any standard mechanical rate, so the
        // baseline genuinely represents the floor — not other peaks.
        var bgMags: [Double] = []
        var f = 3.0
        while f <= 12.0 {
            var nearStandard = false
            for r in standardBeatHzs {
                if abs(f - r) < 0.5 { nearStandard = true; break }
            }
            if !nearStandard {
                bgMags.append(goertzelMagnitude(series: series, frameRate: frameRate, targetHz: f))
            }
            f += 0.25
        }
        guard !bgMags.isEmpty else { return 0 }
        bgMags.sort()
        let median = bgMags[bgMags.count / 2]
        return peak / max(median, 1e-12)
    }

    /// Single-frequency Goertzel filter — O(N) evaluation of one FFT
    /// bin without computing the full FFT. Returns |result| (magnitude).
    private static func goertzelMagnitude(series: [Float], frameRate: Double, targetHz: Double) -> Double {
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
        // Magnitude squared = sPrev² + sPrev2² − coeff·sPrev·sPrev2
        let mag2 = sPrev * sPrev + sPrev2 * sPrev2 - coeff * sPrev * sPrev2
        return sqrt(max(0, mag2))
    }
}
