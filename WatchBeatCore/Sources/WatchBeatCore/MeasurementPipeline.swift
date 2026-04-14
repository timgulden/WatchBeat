import Foundation
import Accelerate

/// Diagnostic data from the measurement pipeline.
public struct PipelineDiagnostics: Sendable {
    public let rawPeakAmplitude: Float
    public let periodEstimate: PeriodEstimate
    public let tickCount: Int
    public let sampleRate: Double
    public let sampleCount: Int
    /// FFT magnitudes at each candidate rate (for debugging).
    public let rateScores: [(rate: StandardBeatRate, magnitude: Float)]
}

/// Measures watch beat rate from raw audio.
///
/// Pipeline:
/// 1. FFT of raw signal — score each of 7 standard rates by spectral magnitude
///    near that frequency. The correct rate has periodic energy; noise doesn't.
/// 2. Guided tick extraction — divide the raw signal into beat-length windows
///    at the winning rate's period. Find the energy peak in each window.
/// 3. Regression — linear fit on confirmed tick positions gives precise period.
///    Deviation from nominal = rate error in s/day. Even/odd residuals = beat error.
public struct MeasurementPipeline {

    public init() {}

    /// Run the pipeline with optional manual rate override.
    /// - Parameter knownRate: If provided, skip rate detection and use this rate directly.
    public func measure(_ input: AudioBuffer, knownRate: StandardBeatRate? = nil) -> MeasurementResult {
        let (result, _) = measureWithDiagnostics(input, knownRate: knownRate)
        return result
    }

    /// Run the pipeline with diagnostics and optional manual rate override.
    public func measureWithDiagnostics(_ input: AudioBuffer, knownRate: StandardBeatRate? = nil) -> (MeasurementResult, PipelineDiagnostics) {
        let samples = input.samples
        let sampleRate = input.sampleRate
        let n = samples.count

        // Step 1: Compute envelope and FFT it for rate identification.
        // Rectification (abs) demodulates the carrier — converts kHz tick bursts
        // into positive bumps. Lowpass at 50 Hz removes carrier residue.
        // Decimation to ~1 kHz reduces FFT size. The result has clear peaks
        // at the tick rate regardless of the carrier frequency.
        let envelope = computeEnvelope(samples: samples, sampleRate: sampleRate)
        let envFftLength = nextPowerOfTwo(envelope.samples.count)
        let magnitudes = computeFFTMagnitudes(samples: envelope.samples, fftLength: envFftLength)
        let freqResolution = envelope.sampleRate / Double(envFftLength)

        // Step 2: Score each standard rate by envelope FFT magnitude.
        var rateScores: [(rate: StandardBeatRate, magnitude: Float)] = []

        for rate in StandardBeatRate.allCases {
            let fundMag = peakMagnitudeNear(magnitudes: magnitudes, freqResolution: freqResolution, hz: rate.hz)
            rateScores.append((rate, fundMag))
        }

        rateScores.sort { $0.magnitude > $1.magnitude }

        // Step 3: Determine candidate rates.
        // If the caller specified a known rate, use it directly.
        // If the envelope FFT has a clear winner (>30% above second place), trust it.
        // Otherwise, try all rates and let guided extraction decide.
        let candidateRates: [StandardBeatRate]
        if let known = knownRate {
            candidateRates = [known]
        } else {
            let topMag = rateScores.first?.magnitude ?? 0
            let secondMag = rateScores.count > 1 ? rateScores[1].magnitude : 0
            let fftIsClear = topMag > 0 && secondMag > 0 && (topMag / secondMag) > 1.3

            if fftIsClear {
                candidateRates = [rateScores.first!.rate]
            } else {
                candidateRates = StandardBeatRate.allCases
            }
        }

        var bestResult: MeasurementResult?
        var bestTickResult: TickExtractionResult?
        var bestScore: Double = -1
        var bestRate = knownRate ?? rateScores.first?.rate ?? StandardBeatRate.bph28800

        for rate in candidateRates {
            let measuredHz = interpolateFFTPeak(
                magnitudes: magnitudes, freqResolution: freqResolution, nearHz: rate.hz
            )

            let tickResult = extractTicks(
                samples: samples, sampleRate: sampleRate,
                rate: rate, measuredHz: measuredHz
            )

            // Score: three factors that together identify the correct rate.
            // 1. Recovery rate: fraction of expected ticks that were confirmed.
            // 2. Residual quality: how well tick positions fit a straight line.
            // 3. Period consistency: regression slope must match the candidate's
            //    expected period. A wrong rate might find real ticks (low residuals)
            //    but the measured period will be wrong for that rate.
            let duration = Double(n) / sampleRate
            let expectedTicks = duration * rate.hz
            let recoveryRate = min(1.0, Double(tickResult.confirmedCount) / max(1.0, expectedTicks))
            let residualQuality = tickResult.residualStd > 0 && tickResult.residualStd < .infinity
                ? exp(-tickResult.residualStd / (rate.nominalPeriodSeconds * 0.05))
                : 0.0

            // Period consistency: penalize if measured period is far from nominal
            let periodConsistency: Double
            if let measuredPeriod = tickResult.measuredPeriod {
                let periodDeviation = abs(measuredPeriod - rate.nominalPeriodSeconds) / rate.nominalPeriodSeconds
                // Allow up to ~1% deviation (≈864 s/day); heavily penalize beyond that
                periodConsistency = exp(-periodDeviation / 0.01)
            } else {
                periodConsistency = 0.0
            }

            // Also factor in envelope FFT magnitude as a tiebreaker
            let envMag = rateScores.first(where: { $0.rate == rate })?.magnitude ?? 0
            let maxEnvMag = rateScores.first?.magnitude ?? 1
            let envBoost = maxEnvMag > 0 ? Double(envMag / maxEnvMag) : 0

            let score = recoveryRate * residualQuality * periodConsistency * (0.5 + 0.5 * envBoost)

            if score > bestScore {
                bestScore = score
                bestRate = rate
                bestTickResult = tickResult
            }
        }

        let tickResult = bestTickResult ?? TickExtractionResult(
            confirmedCount: 0, qualityScore: 0, beatErrorMs: nil, amplitudeProxy: 0, measuredPeriod: nil, residualStd: .infinity
        )

        // Step 4: Rate error from tick regression
        let nominalPeriod = bestRate.nominalPeriodSeconds
        let rateError: Double
        if let measuredPeriod = tickResult.measuredPeriod {
            rateError = (nominalPeriod - measuredPeriod) / nominalPeriod * 86400.0
        } else {
            let measuredHz = interpolateFFTPeak(
                magnitudes: magnitudes, freqResolution: freqResolution, nearHz: bestRate.hz
            )
            let fftPeriod = measuredHz > 0 ? 1.0 / measuredHz : nominalPeriod
            rateError = (nominalPeriod - fftPeriod) / nominalPeriod * 86400.0
        }

        let confidence = computeConfidence(rateScores: rateScores, bestRate: bestRate)

        let result = MeasurementResult(
            snappedRate: bestRate,
            rateErrorSecondsPerDay: rateError,
            beatErrorMilliseconds: tickResult.beatErrorMs,
            amplitudeProxy: tickResult.amplitudeProxy,
            qualityScore: tickResult.qualityScore,
            tickCount: tickResult.confirmedCount
        )

        let bestMeasuredHz = tickResult.measuredPeriod.map { 1.0 / $0 } ?? bestRate.hz
        let periodEstimate = PeriodEstimate(
            measuredHz: bestMeasuredHz, snappedRate: bestRate, confidence: confidence
        )

        let diagnostics = PipelineDiagnostics(
            rawPeakAmplitude: samples.map { abs($0) }.max() ?? 0,
            periodEstimate: periodEstimate,
            tickCount: tickResult.confirmedCount,
            sampleRate: sampleRate,
            sampleCount: n,
            rateScores: rateScores
        )

        return (result, diagnostics)
    }

    // MARK: - Envelope

    /// Rectify + lowpass + decimate to extract the tick repetition envelope.
    private func computeEnvelope(samples: [Float], sampleRate: Double) -> (samples: [Float], sampleRate: Double) {
        let n = samples.count

        // Rectify: abs(signal)
        var rectified = [Float](repeating: 0, count: n)
        vDSP_vabs(samples, 1, &rectified, 1, vDSP_Length(n))

        // Lowpass at 50 Hz using a simple moving average.
        // Window size = sampleRate / (2 * cutoff) to get -3dB at ~50 Hz.
        let cutoff = 50.0
        let avgWindow = max(3, Int(sampleRate / (2.0 * cutoff)))
        let smoothedCount = n - avgWindow + 1
        guard smoothedCount > 0 else { return (rectified, sampleRate) }

        var smoothed = [Float](repeating: 0, count: smoothedCount)
        // Running sum for efficiency
        var sum: Float = 0
        for i in 0..<avgWindow { sum += rectified[i] }
        smoothed[0] = sum / Float(avgWindow)
        for i in 1..<smoothedCount {
            sum += rectified[i + avgWindow - 1] - rectified[i - 1]
            smoothed[i] = sum / Float(avgWindow)
        }

        // Decimate to ~1 kHz
        let decimFactor = max(1, Int(sampleRate / 1000.0))
        let decimCount = smoothedCount / decimFactor
        guard decimCount > 0 else { return (smoothed, sampleRate) }

        var decimated = [Float](repeating: 0, count: decimCount)
        for i in 0..<decimCount {
            decimated[i] = smoothed[i * decimFactor]
        }

        return (decimated, sampleRate / Double(decimFactor))
    }

    // MARK: - FFT

    private func computeFFTMagnitudes(samples: [Float], fftLength: Int) -> [Float] {
        let n = samples.count

        // Window the signal
        var windowed = [Float](repeating: 0, count: n)
        var hannWindow = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hannWindow, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, hannWindow, 1, &windowed, 1, vDSP_Length(n))

        // Zero-pad
        var padded = [Float](repeating: 0, count: fftLength)
        padded.replaceSubrange(0..<n, with: windowed)

        let log2n = vDSP_Length(log2(Double(fftLength)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
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

        // sqrt for magnitude
        var sqrtMag = [Float](repeating: 0, count: halfN)
        var count32 = Int32(halfN)
        vvsqrtf(&sqrtMag, magnitudes, &count32)

        return sqrtMag
    }

    /// Peak FFT magnitude in a small window around a target frequency.
    private func peakMagnitudeNear(magnitudes: [Float], freqResolution: Double, hz: Double) -> Float {
        let targetBin = Int(round(hz / freqResolution))
        let windowRadius = max(1, Int(ceil(0.5 / freqResolution))) // ±0.5 Hz
        let lo = max(0, targetBin - windowRadius)
        let hi = min(magnitudes.count - 1, targetBin + windowRadius)
        var peak: Float = 0
        for bin in lo...hi {
            peak = max(peak, magnitudes[bin])
        }
        return peak
    }

    /// Parabolic interpolation around the FFT peak nearest to a target frequency.
    private func interpolateFFTPeak(magnitudes: [Float], freqResolution: Double, nearHz: Double) -> Double {
        let halfN = magnitudes.count
        let targetBin = Int(round(nearHz / freqResolution))
        let searchRadius = max(3, Int(Double(targetBin) * 0.15))
        let minBin = max(1, targetBin - searchRadius)
        let maxBin = min(halfN - 2, targetBin + searchRadius)
        guard minBin < maxBin else { return nearHz }

        var peakBin = minBin
        var peakMag = magnitudes[minBin]
        for bin in (minBin + 1)...maxBin {
            if magnitudes[bin] > peakMag {
                peakMag = magnitudes[bin]
                peakBin = bin
            }
        }

        guard peakBin > minBin && peakBin < maxBin else {
            return Double(peakBin) * freqResolution
        }

        let alpha = magnitudes[peakBin - 1]
        let beta = magnitudes[peakBin]
        let gamma = magnitudes[peakBin + 1]
        let denom = alpha - 2.0 * beta + gamma
        let offset: Float = abs(denom) > 1e-10 ? 0.5 * (alpha - gamma) / denom : 0

        return (Double(peakBin) + Double(offset)) * freqResolution
    }

    private func computeConfidence(rateScores: [(rate: StandardBeatRate, magnitude: Float)], bestRate: StandardBeatRate) -> Double {
        guard let bestMag = rateScores.first(where: { $0.rate == bestRate })?.magnitude,
              bestMag > 0 else { return 0 }
        let otherMax = rateScores.filter { $0.rate != bestRate }.map { $0.magnitude }.max() ?? 0
        let ratio = otherMax > 0 ? Double(bestMag / otherMax) : 10.0
        return min(1.0, max(0.0, 1.0 - exp(-(ratio - 1.0) / 2.0)))
    }

    // MARK: - Guided tick extraction

    private struct TickExtractionResult {
        let confirmedCount: Int
        let qualityScore: Double
        let beatErrorMs: Double?
        let amplitudeProxy: Double
        let measuredPeriod: Double?
        /// Regression residual std dev in seconds. Low = ticks fit the rate well.
        let residualStd: Double
    }

    /// Divide the raw signal into beat-length windows, find energy peaks.
    /// Tries two window offsets (0 and half-period) to avoid the boundary problem
    /// where ticks landing near window edges split their energy and get missed.
    private func extractTicks(
        samples: [Float], sampleRate: Double,
        rate: StandardBeatRate, measuredHz: Double
    ) -> TickExtractionResult {
        let n = samples.count
        let period = measuredHz > 0 ? 1.0 / measuredHz : rate.nominalPeriodSeconds
        let periodSamples = Int(round(period * sampleRate))

        guard periodSamples > 10 && periodSamples < n / 3 else {
            return TickExtractionResult(confirmedCount: 0, qualityScore: 0,
                                        beatErrorMs: nil, amplitudeProxy: 0, measuredPeriod: nil, residualStd: .infinity)
        }

        // Squared signal for energy measurement
        var squared = [Float](repeating: 0, count: n)
        vDSP_vsq(samples, 1, &squared, 1, vDSP_Length(n))

        // Try 5 evenly spaced starting offsets across one period.
        // With 5 offsets, no tick can be closer than 1/10 of a period from the
        // nearest window center. Pick whichever offset finds the most confirmed ticks.
        let numOffsets = 5
        var bestResult = TickExtractionResult(confirmedCount: 0, qualityScore: 0,
                                               beatErrorMs: nil, amplitudeProxy: 0,
                                               measuredPeriod: nil, residualStd: .infinity)

        for k in 0..<numOffsets {
            let offset = k * periodSamples / numOffsets
            let result = extractTicksAtOffset(
                squared: squared, n: n, sampleRate: sampleRate, rate: rate,
                periodSamples: periodSamples, startOffset: offset
            )
            if result.confirmedCount > bestResult.confirmedCount {
                bestResult = result
            }
        }

        return bestResult
    }

    /// Extract ticks with windows starting at a specific offset.
    private func extractTicksAtOffset(
        squared: [Float], n: Int, sampleRate: Double, rate: StandardBeatRate,
        periodSamples: Int, startOffset: Int
    ) -> TickExtractionResult {
        // Divide into windows from startOffset, find peak in each
        let usableLength = n - startOffset
        let numWindows = usableLength / periodSamples
        guard numWindows >= 3 else {
            return TickExtractionResult(confirmedCount: 0, qualityScore: 0,
                                        beatErrorMs: nil, amplitudeProxy: 0, measuredPeriod: nil, residualStd: .infinity)
        }

        var peakOffsets = [Int](repeating: 0, count: numWindows)

        for w in 0..<numWindows {
            let wStart = startOffset + w * periodSamples
            var bestIdx = 0
            var bestVal: Float = 0
            for i in 0..<periodSamples {
                if squared[wStart + i] > bestVal {
                    bestVal = squared[wStart + i]
                    bestIdx = i
                }
            }
            peakOffsets[w] = bestIdx
        }

        // Median peak offset — this is where ticks naturally fall within each window.
        // Robust to noise: even if some windows have noise peaks at random positions,
        // the median reflects the true tick position.
        let medianOffset = sortedMedianInt(peakOffsets)

        // Re-window centered on the median offset, with a search window
        // of 40% of the period for the peak to drift within.
        let tickWindow = max(10, Int(Double(periodSamples) * 0.2))
        let halfTick = tickWindow / 2

        var tickEnergies: [Float] = []
        var gapEnergies: [Float] = []
        var peakTimes: [Double] = []

        for w in 0..<numWindows {
            let windowCenter = startOffset + w * periodSamples + medianOffset
            guard windowCenter >= halfTick && windowCenter + halfTick < n else { continue }

            let wStart = windowCenter - halfTick

            // Tick energy in the search window
            var energy: Float = 0
            vDSP_sve(squared.withUnsafeBufferPointer { $0.baseAddress! + wStart },
                     1, &energy, vDSP_Length(tickWindow))
            tickEnergies.append(energy)

            // Peak position within window (sub-sample)
            var peakIdx = 0
            var peakVal: Float = 0
            for i in 0..<tickWindow {
                if squared[wStart + i] > peakVal {
                    peakVal = squared[wStart + i]
                    peakIdx = i
                }
            }
            let absIdx = wStart + peakIdx
            if absIdx > 0 && absIdx < n - 1 {
                let a = squared[absIdx - 1], b = squared[absIdx], c = squared[absIdx + 1]
                let d = a - 2.0 * b + c
                let off: Float = abs(d) > 1e-15 ? 0.5 * (a - c) / d : 0
                peakTimes.append((Double(absIdx) + Double(off)) / sampleRate)
            } else {
                peakTimes.append(Double(absIdx) / sampleRate)
            }

            // Gap energy: midpoint between this tick and next
            let gapCenter = startOffset + w * periodSamples + medianOffset + periodSamples / 2
            if gapCenter >= halfTick && gapCenter + halfTick < n {
                var gapE: Float = 0
                vDSP_sve(squared.withUnsafeBufferPointer { $0.baseAddress! + gapCenter - halfTick },
                         1, &gapE, vDSP_Length(tickWindow))
                gapEnergies.append(gapE)
            }
        }

        guard tickEnergies.count >= 3 else {
            return TickExtractionResult(confirmedCount: 0, qualityScore: 0,
                                        beatErrorMs: nil, amplitudeProxy: 0, measuredPeriod: nil, residualStd: .infinity)
        }

        // Confirm ticks: energy must exceed gap energy
        let medianGap = sortedMedian(gapEnergies)
        let threshold = medianGap * 2.0
        var confirmed: [Int] = []
        for i in 0..<tickEnergies.count {
            if tickEnergies[i] > threshold || medianGap == 0 {
                confirmed.append(i)
            }
        }

        guard confirmed.count >= 3 else {
            return TickExtractionResult(confirmedCount: tickEnergies.count, qualityScore: 0,
                                        beatErrorMs: nil, amplitudeProxy: 0, measuredPeriod: nil, residualStd: .infinity)
        }

        // Quality from SNR
        let medianTick = sortedMedian(tickEnergies.map { $0 })
        let snr = medianGap > 0 ? Double(medianTick / medianGap) : 100.0
        let quality = min(1.0, max(0.0, 1.0 - exp(-snr / 5.0)))

        // Regression on confirmed tick peak positions
        let regression = linearRegression(times: peakTimes, indices: confirmed)

        // Beat error
        let beatError: Double?
        if !rate.isQuartz && confirmed.count >= 6, let slope = regression.slope, let intercept = regression.intercept {
            var evenRes: [Double] = [], oddRes: [Double] = []
            for i in confirmed {
                let predicted = slope * Double(i) + intercept
                let residual = peakTimes[i] - predicted
                if i % 2 == 0 { evenRes.append(residual) } else { oddRes.append(residual) }
            }
            if !evenRes.isEmpty && !oddRes.isEmpty {
                let eMean = evenRes.reduce(0, +) / Double(evenRes.count)
                let oMean = oddRes.reduce(0, +) / Double(oddRes.count)
                beatError = abs(eMean - oMean) * 1000.0
            } else {
                beatError = nil
            }
        } else {
            beatError = nil
        }

        return TickExtractionResult(
            confirmedCount: confirmed.count,
            qualityScore: quality,
            beatErrorMs: beatError,
            amplitudeProxy: Double(medianTick),
            measuredPeriod: regression.slope,
            residualStd: regression.residualStd
        )
    }

    // MARK: - Helpers

    private func sortedMedianInt(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private struct RegressionResult {
        let slope: Double?
        let intercept: Double?
        let residualStd: Double
    }

    private func linearRegression(times: [Double], indices: [Int]) -> RegressionResult {
        var sumX: Double = 0, sumY: Double = 0, sumXY: Double = 0, sumXX: Double = 0
        var count: Double = 0
        for i in indices {
            guard i < times.count else { continue }
            let x = Double(i), y = times[i]
            sumX += x; sumY += y; sumXY += x * y; sumXX += x * x
            count += 1
        }
        let denom = count * sumXX - sumX * sumX
        guard abs(denom) > 1e-20 && count >= 3 else {
            return RegressionResult(slope: nil, intercept: nil, residualStd: .infinity)
        }
        let slope = (count * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / count

        // Compute residual std dev
        var sumSqRes: Double = 0
        for i in indices {
            guard i < times.count else { continue }
            let predicted = slope * Double(i) + intercept
            let residual = times[i] - predicted
            sumSqRes += residual * residual
        }
        let residualStd = count > 2 ? sqrt(sumSqRes / (count - 2)) : .infinity

        return RegressionResult(slope: slope, intercept: intercept, residualStd: residualStd)
    }

    private func sortedMedian(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func nextPowerOfTwo(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16
        return v + 1
    }
}
