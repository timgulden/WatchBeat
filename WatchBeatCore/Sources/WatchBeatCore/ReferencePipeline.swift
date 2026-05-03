import Foundation
import Accelerate

/// The Reference picker. Lives as an extension on MeasurementPipeline so
/// it shares the conditioner instance and other dependencies with the
/// production picker, while keeping its ~400 lines of body out of the
/// main pipeline file.
///
/// Architecture (CLAUDE.md rules 3, 7, 8):
///   - Single 5 kHz highpass cutoff (no dual-pass).
///   - Try-all-rates with composite scoring; rateConsistency factor
///     handles harmonic disambiguation in the score.
///   - Per-class quadratic-MAD outlier rejection (delegated to
///     OutlierRejector) before linear regression.
///
/// The candidate ranking type lives in ReferenceCandidate.swift.
extension MeasurementPipeline {

    public func measureReference(_ input: AudioBuffer) -> MeasurementResult {
        let (result, _) = measureReferenceWithDiagnostics(input)
        return result
    }

    public func measureReferenceWithDiagnostics(_ input: AudioBuffer) -> (MeasurementResult, PipelineDiagnostics) {
        let sampleRate = input.sampleRate
        let filtered = conditioner.highpassFilter(input.samples, sampleRate: sampleRate, cutoff: Self.highpassCutoffHz)
        let n = filtered.count

        // Squared + 1 ms boxcar smoothing (light — preserves peak location
        // without averaging adjacent sub-events).
        var squared = [Float](repeating: 0, count: n)
        vDSP_vsq(filtered, 1, &squared, 1, vDSP_Length(n))
        let smoothWin = max(3, Int(0.001 * sampleRate)) | 1
        let smoothed = movingAverage(of: squared, windowSamples: smoothWin)

        // Decimate to 1 kHz for FFT.
        let decimFactor = max(1, Int(sampleRate / 1000.0))
        let envRate = sampleRate / Double(decimFactor)
        let envN = n / decimFactor
        var env = [Float](repeating: 0, count: envN)
        for i in 0..<envN {
            var ws: Float = 0
            vDSP_sve(squared.withUnsafeBufferPointer { $0.baseAddress! + i * decimFactor }, 1,
                     &ws, vDSP_Length(decimFactor))
            env[i] = ws / Float(decimFactor)
        }
        var meanEnv: Float = 0
        vDSP_meanv(env, 1, &meanEnv, vDSP_Length(envN))
        var negMean = -meanEnv
        vDSP_vsadd(env, 1, &negMean, &env, 1, vDSP_Length(envN))

        // Hann + complex FFT.
        var hann = [Float](repeating: 0, count: envN)
        vDSP_hann_window(&hann, vDSP_Length(envN), Int32(vDSP_HANN_NORM))
        vDSP_vmul(env, 1, hann, 1, &env, 1, vDSP_Length(envN))

        let fftLength = nextPowerOfTwo(envN)
        var padded = [Float](repeating: 0, count: fftLength)
        padded.replaceSubrange(0..<envN, with: env)
        let log2n = vDSP_Length(log2(Double(fftLength)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return (Self.emptyResult(sampleRate: sampleRate), Self.emptyDiagnostics(sampleRate: sampleRate, n: n))
        }
        defer { vDSP_destroy_fftsetup(setup) }
        let halfN = fftLength / 2
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)
        padded.withUnsafeBufferPointer { buf in
            for i in 0..<halfN {
                realPart[i] = buf[2 * i]
                imagPart[i] = buf[2 * i + 1]
            }
        }
        realPart.withUnsafeMutableBufferPointer { rb in
            imagPart.withUnsafeMutableBufferPointer { ib in
                var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        // ===== Rate selection by per-rate picker scoring =====
        //
        // Find each standard band's FFT peak, then RUN THE PICKER at each
        // candidate rate. The right rate produces high confirmedFraction
        // (real ticks at predicted positions) and low σ (consistent picks);
        // wrong rates produce low confirmedFraction (windows miss real
        // ticks) and high σ (picks land on noise). This is more robust
        // than picking by FFT magnitude alone — on lossy recordings (e.g.
        // YouTube → speaker → mic) the FFT magnitudes at 5/5.5/6 Hz are
        // often within 10% of each other and band magnitude can't tell us
        // which is the watch.
        let freqRes = envRate / Double(fftLength)
        let standardHzs: [Double] = [5.0, 5.5, 6.0, 7.0, 8.0, 10.0]
        let bandRadiusHz = 0.5
        let bandRadius = max(2, Int(ceil(bandRadiusHz / freqRes)))

        // Helper: run the FFT-anchored picker for a given band's peak bin
        // and return a ReferenceCandidate, or nil if not enough beats.
        let durationSec = Double(n) / sampleRate
        let snrHalfSamples = max(1, Int(0.005 * sampleRate))
        func candidate(forBin bin: Int, peakMag: Float) -> ReferenceCandidate? {
            // Sub-bin frequency via parabolic interpolation.
            var fHz = Double(bin) * freqRes
            if bin > 1 && bin < halfN - 1 {
                let mL = sqrt(Double(realPart[bin - 1] * realPart[bin - 1] + imagPart[bin - 1] * imagPart[bin - 1]))
                let mP = Double(peakMag)
                let mR = sqrt(Double(realPart[bin + 1] * realPart[bin + 1] + imagPart[bin + 1] * imagPart[bin + 1]))
                let denom = mL - 2 * mP + mR
                if abs(denom) > 1e-12 {
                    var delta = 0.5 * (mL - mR) / denom
                    if delta > 0.5 { delta = 0.5 }
                    if delta < -0.5 { delta = -0.5 }
                    fHz = (Double(bin) + delta) * freqRes
                }
            }
            let phi = atan2(Double(imagPart[bin]), Double(realPart[bin]))
            let snappedRate = StandardBeatRate.allCases.min { a, b in
                abs(a.hz - fHz) < abs(b.hz - fHz)
            } ?? StandardBeatRate.bph28800

            let periodSec = 1.0 / fHz
            let halfPeriodSamples = Int(periodSec * sampleRate / 2.0)
            let phaseShift = phi / (2.0 * .pi)
            var windowCenters: [Double] = []
            var k = Int(ceil(phaseShift + (Double(halfPeriodSamples) / sampleRate) * fHz))
            while true {
                let t = (Double(k) - phaseShift) / fHz
                if t + Double(halfPeriodSamples) / sampleRate >= durationSec { break }
                if t - Double(halfPeriodSamples) / sampleRate >= 0 { windowCenters.append(t) }
                k += 1
            }

            var beatPositions: [Double] = []
            for tc in windowCenters {
                let centerSample = Int(round(tc * sampleRate))
                let lo = max(0, centerSample - halfPeriodSamples)
                let hi = min(n - 1, centerSample + halfPeriodSamples)
                var bestIdx = lo
                var bestVal: Float = -.infinity
                for i in lo...hi {
                    if smoothed[i] > bestVal { bestVal = smoothed[i]; bestIdx = i }
                }
                beatPositions.append(Double(bestIdx) / sampleRate)
            }

            let m = beatPositions.count
            guard m >= 6 else { return nil }

            // Per-window energies — compute BEFORE regression so we can
            // gate which beats contribute to the slope and σ.
            var tickEnergies: [Float] = []
            var gapEnergies: [Float] = []
            tickEnergies.reserveCapacity(m)
            gapEnergies.reserveCapacity(m - 1)
            for i in 0..<m {
                let center = Int(round(beatPositions[i] * sampleRate))
                let lo = max(0, center - snrHalfSamples)
                let hi = min(n - 1, center + snrHalfSamples)
                if lo < hi {
                    var sum: Float = 0
                    vDSP_sve(squared.withUnsafeBufferPointer { $0.baseAddress! + lo }, 1,
                             &sum, vDSP_Length(hi - lo + 1))
                    tickEnergies.append(sum)
                } else {
                    tickEnergies.append(0)  // align indices with beatPositions
                }
                if i > 0 {
                    let gapCenter = Int(round((beatPositions[i - 1] + beatPositions[i]) * 0.5 * sampleRate))
                    let glo = max(0, gapCenter - snrHalfSamples)
                    let ghi = min(n - 1, gapCenter + snrHalfSamples)
                    if glo < ghi {
                        var gsum: Float = 0
                        vDSP_sve(squared.withUnsafeBufferPointer { $0.baseAddress! + glo }, 1,
                                 &gsum, vDSP_Length(ghi - glo + 1))
                        gapEnergies.append(gsum)
                    }
                }
            }
            let sortedGap = gapEnergies.sorted()
            let medianGap = sortedGap.isEmpty ? 0 : sortedGap[sortedGap.count / 2]

            // Per-window confirmation — production-style gate, applied
            // BEFORE regression. A window passes if its peak energy is at
            // least 2× the median gap energy. Wrong rates produce many
            // unconfirmed windows (argmax landed on noise that's not
            // distinguishable from background); right rates produce most
            // windows confirmed. Only confirmed beats feed the regression
            // and σ — so noisy outlier picks (e.g., the section of EbayVid
            // where video voiceover drowned out the watch) don't pollute
            // the rate estimate.
            let confirmThreshold = medianGap > 0 ? medianGap * 2 : 0
            var confirmedBeatIndices: [Int] = []
            confirmedBeatIndices.reserveCapacity(m)
            for i in 0..<m where tickEnergies[i] > confirmThreshold {
                confirmedBeatIndices.append(i)
            }
            let confirmedFraction = m > 0 ? Double(confirmedBeatIndices.count) / Double(m) : 0
            guard confirmedBeatIndices.count >= 6 else { return nil }

            // Per-class quadratic outlier rejection. See OutlierRejector
            // for the algorithm and rationale; we fit a quadratic per
            // class (tick / tock) and use it ONLY as a flexible reference
            // line for residuals. The linear fit below uses the cleaned
            // set and is what gets reported. No mode switching, no fallback.
            let rejector = OutlierRejector(beatPositions: beatPositions)
            let evenIdxs = confirmedBeatIndices.filter { $0 % 2 == 0 }
            let oddIdxs = confirmedBeatIndices.filter { $0 % 2 != 0 }
            let cleanedConfirmed = (rejector.clean(evenIdxs) + rejector.clean(oddIdxs)).sorted()
            guard cleanedConfirmed.count >= 6 else { return nil }

            // Linear regression on the cleaned set. Use the original beat
            // index `i` (not a re-numbering) so the regression's slope is
            // genuinely seconds-per-beat at the candidate rate.
            var sumI: Double = 0, sumT: Double = 0, sumII: Double = 0, sumIT: Double = 0
            for idx in cleanedConfirmed {
                let di = Double(idx)
                sumI += di; sumT += beatPositions[idx]; sumII += di * di; sumIT += di * beatPositions[idx]
            }
            let cm = Double(cleanedConfirmed.count)
            let regDenom = cm * sumII - sumI * sumI
            let slope = (cm * sumIT - sumI * sumT) / regDenom
            let intercept = (sumT - slope * sumI) / cm

            // Residuals over ALL beats so the timegraph still has every
            // pick (confirmed and unconfirmed). Per-class σ uses
            // CONFIRMED beats only — unconfirmed picks are noise and would
            // inflate σ artificially.
            var residualsMs = [Double](repeating: 0, count: m)
            for i in 0..<m {
                residualsMs[i] = (beatPositions[i] - (slope * Double(i) + intercept)) * 1000.0
            }
            var evenSum = 0.0, oddSum = 0.0, evenSumSq = 0.0, oddSumSq = 0.0, evenN = 0, oddN = 0
            for idx in cleanedConfirmed {
                let r = residualsMs[idx]
                if idx % 2 == 0 {
                    evenSum += r; evenSumSq += r * r; evenN += 1
                } else {
                    oddSum += r; oddSumSq += r * r; oddN += 1
                }
            }
            let evenMean = evenN > 0 ? evenSum / Double(evenN) : 0
            let oddMean = oddN > 0 ? oddSum / Double(oddN) : 0
            let evenVar = evenN > 0 ? max(0, evenSumSq / Double(evenN) - evenMean * evenMean) : 0
            let oddVar = oddN > 0 ? max(0, oddSumSq / Double(oddN) - oddMean * oddMean) : 0
            let evenStd = sqrt(evenVar)
            let oddStd = sqrt(oddVar)

            // SNR from confirmed tickEnergies (those passed the gate, so
            // their median is an honest "typical real-tick energy") vs
            // medianGap (background).
            let confirmedTickEnergies = confirmedBeatIndices.map { tickEnergies[$0] }.sorted()
            let medianTick = confirmedTickEnergies.isEmpty ? 0 : confirmedTickEnergies[confirmedTickEnergies.count / 2]
            let snr = medianGap > 0 ? Double(medianTick / medianGap) : 100.0
            let cf = confirmedFraction

            return ReferenceCandidate(
                snappedRate: snappedRate,
                fHz: fHz, phi: phi,
                beatPositions: beatPositions,
                slope: slope, intercept: intercept,
                residualsMs: residualsMs,
                evenMean: evenMean, oddMean: oddMean,
                evenStd: evenStd, oddStd: oddStd,
                avgClassStd: (evenStd + oddStd) / 2.0,
                beAsymmetryMs: abs(evenMean - oddMean),
                tickEnergies: tickEnergies, gapEnergies: gapEnergies,
                medianTick: medianTick, medianGap: medianGap,
                snr: snr,
                confirmedFraction: cf,
                cleanedConfirmed: cleanedConfirmed
            )
        }

        // For each standard band, find the peak bin and run the picker.
        var candidates: [ReferenceCandidate] = []
        for hz in standardHzs {
            let center = Int(round(hz / freqRes))
            let lo = max(1, center - bandRadius)
            let hi = min(halfN - 2, center + bandRadius)
            guard lo < hi else { continue }
            var bestBin = -1
            var bestM2: Float = -.infinity
            for b in lo...hi {
                let m2 = realPart[b] * realPart[b] + imagPart[b] * imagPart[b]
                if m2 > bestM2 { bestM2 = m2; bestBin = b }
            }
            if bestBin >= 0, let cand = candidate(forBin: bestBin, peakMag: sqrt(bestM2)) {
                candidates.append(cand)
            }
        }

        // Diagnostic: WATCHBEAT_DEBUG_CANDIDATES=1 dumps each candidate's
        // score breakdown. Useful for tuning the score formula on
        // borderline recordings.
        if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_CANDIDATES"] != nil {
            for c in candidates.sorted(by: { $0.score > $1.score }) {
                FileHandle.standardError.write(
                    "[ref-cand] \(c.snappedRate.rawValue) bph  fHz=\(String(format: "%.4f", c.fHz))  m=\(c.beatPositions.count)  conf=\(String(format: "%.2f", c.confirmedFraction))  σ=\(String(format: "%.2f", c.avgClassStd))  snr=\(String(format: "%.1f", c.snr))  score=\(String(format: "%.4f", c.score))\n".data(using: .utf8)!)
            }
        }
        guard let winner = candidates.max(by: { $0.score < $1.score }) else {
            return (Self.emptyResult(sampleRate: sampleRate), Self.emptyDiagnostics(sampleRate: sampleRate, n: n))
        }

        // Unpack the winning candidate into the locals that the rest of the
        // function used to compute directly.
        let snappedRate = winner.snappedRate
        let beatPositions = winner.beatPositions
        let m = beatPositions.count
        let slope = winner.slope
        let intercept = winner.intercept
        let residualsMs = winner.residualsMs
        let avgClassStd = winner.avgClassStd
        let beAsymmetryMs = winner.beAsymmetryMs
        let snr = winner.snr
        let confirmedFraction = winner.confirmedFraction
        let rateErrPerDay = (winner.fHz / snappedRate.hz - 1.0) * 86400.0

        // Quality from the winner's SNR. Same formula as before — see notes
        // on tightening from snr/5 to snr/10 to keep pure noise (snr ~ 2)
        // below the 30% display gate while real watches saturate above 50.
        let quality = max(0.0, min(1.0, 1.0 - exp(-snr / 10.0)))

        // Routing: distinguish three classes of "high σ" by what we still
        // know about the recording.
        //
        // 1. σ > 10 ms AND confirmedFraction < 0.5
        //    → bad recording (most windows had no detectable tick).
        //    → isLowConfidence = true; iOS routes to Low Analytical
        //      Confidence page.
        //
        // 2. σ > 10 ms AND confirmedFraction ≥ 0.5
        //    → ticks ARE present but timing is messy (lossy speaker→mic
        //      chain, distant mic, room ambience). The FFT still pins the
        //      rate accurately (it integrates over all 15 s, robust to
        //      per-window noise). FALL BACK: report rate from FFT, omit
        //      beat error and timegraph, mark NOT lowConfidence so the
        //      result page shows. The user gets a useful rate reading
        //      even if individual ticks couldn't be pinned to ±1 ms.
        //
        // 3. σ ≤ 10 ms
        //    → normal path; everything reported.
        let highSigma = avgClassStd > 10.0
        let useFftRateFallback = highSigma && confirmedFraction >= 0.5
        let isLowConfidence = highSigma && !useFftRateFallback

        // When using the FFT-rate fallback, suppress beat error and
        // timegraph since they depend on per-tick precision the picker
        // couldn't deliver on this recording.
        let beatErrorReported: Double? = useFftRateFallback ? nil : beAsymmetryMs
        // Only emit ticks that survived outlier rejection. A pick that
        // failed the per-class quadratic-MAD test is almost certainly a
        // misread (noise event in the gap, wrong sub-event, etc.) — not a
        // real beat that happened at a wildly different time. Don't show
        // it on the timegraph.
        let tickTimings: [TickTiming]
        if useFftRateFallback {
            tickTimings = []
        } else {
            let kept = Set(winner.cleanedConfirmed)
            tickTimings = (0..<m).compactMap { i -> TickTiming? in
                guard kept.contains(i) else { return nil }
                return TickTiming(beatIndex: i, residualMs: residualsMs[i], isEvenBeat: i % 2 == 0)
            }
        }

        // Amplitude proxy: median peak amplitude in smoothed envelope at
        // each beat position. The picker already located each beat's argmax
        // — read smoothed[that index] directly rather than re-searching.
        var peakValues: [Float] = []
        peakValues.reserveCapacity(m)
        for bp in beatPositions {
            let idx = min(n - 1, max(0, Int(round(bp * sampleRate))))
            peakValues.append(smoothed[idx])
        }
        peakValues.sort()
        let medianPeak = peakValues.isEmpty ? 0 : Double(peakValues[peakValues.count / 2])

        let result = MeasurementResult(
            snappedRate: snappedRate,
            rateErrorSecondsPerDay: rateErrPerDay,
            beatErrorMilliseconds: beatErrorReported,
            amplitudeProxy: medianPeak,
            qualityScore: quality,
            tickCount: m,
            tickTimings: tickTimings,
            isLowConfidence: isLowConfidence,
            measuredPeriod: slope,
            regressionIntercept: intercept,
            confirmedFraction: confirmedFraction
        )

        let diagnostics = PipelineDiagnostics(
            rawPeakAmplitude: 0,
            periodEstimate: PeriodEstimate(measuredHz: 1.0 / slope, snappedRate: snappedRate, confidence: quality),
            tickCount: m,
            sampleRate: sampleRate,
            sampleCount: n,
            rateScores: []
        )
        return (result, diagnostics)
    }

    static func emptyResult(sampleRate: Double) -> MeasurementResult {
        MeasurementResult(
            snappedRate: .bph28800,
            rateErrorSecondsPerDay: 0,
            beatErrorMilliseconds: nil,
            amplitudeProxy: 0,
            qualityScore: 0,
            tickCount: 0,
            tickTimings: [],
            isLowConfidence: true,
            measuredPeriod: nil,
            regressionIntercept: nil
        )
    }

    static func emptyDiagnostics(sampleRate: Double, n: Int) -> PipelineDiagnostics {
        PipelineDiagnostics(
            rawPeakAmplitude: 0,
            periodEstimate: PeriodEstimate(measuredHz: 0, snappedRate: .bph28800, confidence: 0),
            tickCount: 0,
            sampleRate: sampleRate,
            sampleCount: n,
            rateScores: []
        )
    }
}
