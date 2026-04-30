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

    /// Highpass cutoff applied to the raw signal before any other processing.
    /// Watch-tick energy lives almost entirely above ~4 kHz; room rumble, hum,
    /// mic self-noise, and broadband environmental noise (HVAC, washing
    /// machines) dominate below that. 5 kHz is the sweet spot for most
    /// recordings and preserves the 5-8 kHz band that pin-lever Timexes
    /// depend on. 8 kHz helps when there's significant mid-band noise
    /// (HVAC, appliances, voices). We no longer commit to one cutoff — the
    /// pipeline runs at both and picks the higher-quality result.
    public static let highpassCutoffHz: Double = 5000.0

    /// Alternate highpass cutoff tried in parallel. Higher cutoff rescues
    /// noisy-environment recordings that 5 kHz can't separate the ticks from.
    public static let alternateHighpassCutoffHz: Double = 8000.0

    private let conditioner = SignalConditioner()

    public init() {}

    /// Run the pipeline with optional manual rate override.
    /// - Parameter knownRate: If provided, skip rate detection and use this rate directly.
    public func measure(_ input: AudioBuffer, knownRate: StandardBeatRate? = nil) -> MeasurementResult {
        let (result, _) = measureWithDiagnostics(input, knownRate: knownRate)
        return result
    }

    /// Reference-picker alternative measurement path.
    ///
    /// Replaces the production picker's centroid + rate-selection +
    /// matched-filter pipeline with the simpler FFT-phase-anchored argmax
    /// algorithm validated by the standalone Reference CLI:
    ///   1. Highpass 5 kHz → square → 1 ms boxcar smooth.
    ///   2. Decimate squared signal to 1 kHz envelope, FFT, find peak in
    ///      [4, 11] Hz, parabolic-interpolate fHz, read complex phase.
    ///   3. Generate window centers from FFT phase at fHz cadence.
    ///   4. For each window, take ±half-period of full-rate smoothed
    ///      squared, find argmax → that's the beat position.
    ///   5. Linear regression on beat positions; rate is the FFT peak (more
    ///      stable than regression slope in the presence of within-recording
    ///      mechanical wander). Beat error is even/odd asymmetry of
    ///      regression residuals.
    ///
    /// This path was developed for accurately measuring multi-sub-event
    /// Swiss escapements (Omega 485) where the production picker's centroid
    /// hides ~9 ms of real beat error by averaging across sub-events. It
    /// works just as well on single-peak Timex-style ticks because argmax
    /// in a half-period window is degenerate-stable when there's only one
    /// peak.
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

        // Find peak NEAR a standard watch rate. Restricting the search to
        // ±0.5 Hz bands around 5.0, 5.5, 6.0, 7.0, 8.0, 10.0 Hz prevents
        // an environmental noise source (motor/fan/etc.) from outranking
        // the watch when the noise's FFT peak happens to fall outside any
        // standard-rate band — which can otherwise pull the rate decision
        // wildly wrong (e.g., a 9.28 Hz noise on a 21600 bph watch
        // recording snapped to 36000 bph and reported -6240 s/day).
        let freqRes = envRate / Double(fftLength)
        let standardHzs: [Double] = [5.0, 5.5, 6.0, 7.0, 8.0, 10.0]
        let bandRadiusHz = 0.5
        let bandRadius = max(2, Int(ceil(bandRadiusHz / freqRes)))
        var peakBin = -1
        var peakMag2: Float = -.infinity
        for hz in standardHzs {
            let center = Int(round(hz / freqRes))
            let lo = max(1, center - bandRadius)
            let hi = min(halfN - 2, center + bandRadius)
            guard lo < hi else { continue }
            for b in lo...hi {
                let m2 = realPart[b] * realPart[b] + imagPart[b] * imagPart[b]
                if m2 > peakMag2 { peakMag2 = m2; peakBin = b }
            }
        }
        guard peakBin >= 0 else {
            return (Self.emptyResult(sampleRate: sampleRate), Self.emptyDiagnostics(sampleRate: sampleRate, n: n))
        }
        var fHz = Double(peakBin) * freqRes
        if peakBin > 1 && peakBin < halfN - 1 {
            let mL = sqrt(Double(realPart[peakBin - 1] * realPart[peakBin - 1] + imagPart[peakBin - 1] * imagPart[peakBin - 1]))
            let mP = sqrt(Double(peakMag2))
            let mR = sqrt(Double(realPart[peakBin + 1] * realPart[peakBin + 1] + imagPart[peakBin + 1] * imagPart[peakBin + 1]))
            let denom = mL - 2 * mP + mR
            if abs(denom) > 1e-12 {
                var delta = 0.5 * (mL - mR) / denom
                if delta > 0.5 { delta = 0.5 }
                if delta < -0.5 { delta = -0.5 }
                fHz = (Double(peakBin) + delta) * freqRes
            }
        }
        let phi = atan2(Double(imagPart[peakBin]), Double(realPart[peakBin]))

        // Snap to nearest standard rate (for `snappedRate` field; rate
        // ERROR is computed against this nominal).
        let snappedRate = StandardBeatRate.allCases.min { a, b in
            abs(a.hz - fHz) < abs(b.hz - fHz)
        } ?? StandardBeatRate.bph28800
        let rateErrPerDay = (fHz / snappedRate.hz - 1.0) * 86400.0

        // Generate window centers at fHz cadence from FFT phase.
        let periodSec = 1.0 / fHz
        let halfPeriodSamples = Int(periodSec * sampleRate / 2.0)
        let durationSec = Double(n) / sampleRate
        let phaseShift = phi / (2.0 * .pi)
        var windowCenters: [Double] = []
        var k = Int(ceil(phaseShift + (Double(halfPeriodSamples) / sampleRate) * fHz))
        while true {
            let t = (Double(k) - phaseShift) / fHz
            if t + Double(halfPeriodSamples) / sampleRate >= durationSec { break }
            if t - Double(halfPeriodSamples) / sampleRate >= 0 { windowCenters.append(t) }
            k += 1
        }

        // Per-window argmax on smoothed squared (full-rate).
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
        guard m >= 6 else {
            return (Self.emptyResult(sampleRate: sampleRate), Self.emptyDiagnostics(sampleRate: sampleRate, n: n))
        }

        // Linear regression on beat positions.
        var sumI: Double = 0, sumT: Double = 0, sumII: Double = 0, sumIT: Double = 0
        for i in 0..<m {
            let di = Double(i)
            sumI += di; sumT += beatPositions[i]; sumII += di * di; sumIT += di * beatPositions[i]
        }
        let dm = Double(m)
        let regDenom = dm * sumII - sumI * sumI
        let slope = (dm * sumIT - sumI * sumT) / regDenom
        let intercept = (sumT - slope * sumI) / dm

        // Residuals + per-class statistics.
        var residualsMs = [Double](repeating: 0, count: m)
        for i in 0..<m {
            residualsMs[i] = (beatPositions[i] - (slope * Double(i) + intercept)) * 1000.0
        }
        var evenSum: Double = 0, oddSum: Double = 0
        var evenSumSq: Double = 0, oddSumSq: Double = 0
        var evenN = 0, oddN = 0
        for i in 0..<m {
            if i % 2 == 0 {
                evenSum += residualsMs[i]; evenSumSq += residualsMs[i] * residualsMs[i]; evenN += 1
            } else {
                oddSum += residualsMs[i]; oddSumSq += residualsMs[i] * residualsMs[i]; oddN += 1
            }
        }
        let evenMean = evenN > 0 ? evenSum / Double(evenN) : 0
        let oddMean = oddN > 0 ? oddSum / Double(oddN) : 0
        let evenVar = evenN > 0 ? max(0, evenSumSq / Double(evenN) - evenMean * evenMean) : 0
        let oddVar = oddN > 0 ? max(0, oddSumSq / Double(oddN) - oddMean * oddMean) : 0
        let evenStd = sqrt(evenVar)
        let oddStd = sqrt(oddVar)
        let beAsymmetryMs = abs(evenMean - oddMean)

        // Quality from per-class σ. exp(-σ/5) gives:
        //   σ = 0.5 ms → q = 0.90  (clean watch, auto-stop at 80%)
        //   σ = 1.0 ms → q = 0.82  (still auto-stop)
        //   σ = 2.0 ms → q = 0.67  (show result)
        //   σ = 5.0 ms → q = 0.37  (show; borderline)
        //   σ = 8.0 ms → q = 0.20  (try again)
        let avgClassStd = (evenStd + oddStd) / 2.0
        let quality = max(0.0, min(1.0, exp(-avgClassStd / 5.0)))

        // Low confidence: σ comparable to or larger than the typical
        // mechanical variation we care about — picker is not locking
        // consistently enough to trust the displayed numbers.
        let isLowConfidence = avgClassStd > 6.0

        // Tick timings for the timegraph: use the residuals as-is.
        let tickTimings: [TickTiming] = (0..<m).map {
            TickTiming(beatIndex: $0, residualMs: residualsMs[$0], isEvenBeat: $0 % 2 == 0)
        }

        // Amplitude proxy: median peak amplitude. Used for downstream
        // amplitude estimation. For now just return median tick energy.
        var peakValues: [Float] = []
        peakValues.reserveCapacity(m)
        for tc in windowCenters {
            let centerSample = Int(round(tc * sampleRate))
            let lo = max(0, centerSample - halfPeriodSamples)
            let hi = min(n - 1, centerSample + halfPeriodSamples)
            var mx: Float = 0
            for i in lo...hi { if smoothed[i] > mx { mx = smoothed[i] } }
            peakValues.append(mx)
        }
        peakValues.sort()
        let medianPeak = peakValues.isEmpty ? 0 : Double(peakValues[peakValues.count / 2])

        let result = MeasurementResult(
            snappedRate: snappedRate,
            rateErrorSecondsPerDay: rateErrPerDay,
            beatErrorMilliseconds: beAsymmetryMs,
            amplitudeProxy: medianPeak,
            qualityScore: quality,
            tickCount: m,
            tickTimings: tickTimings,
            isLowConfidence: isLowConfidence,
            measuredPeriod: slope,
            regressionIntercept: intercept
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

    private static func emptyResult(sampleRate: Double) -> MeasurementResult {
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

    private static func emptyDiagnostics(sampleRate: Double, n: Int) -> PipelineDiagnostics {
        PipelineDiagnostics(
            rawPeakAmplitude: 0,
            periodEstimate: PeriodEstimate(measuredHz: 0, snappedRate: .bph28800, confidence: 0),
            tickCount: 0,
            sampleRate: sampleRate,
            sampleCount: n,
            rateScores: []
        )
    }

    /// Run the pipeline with diagnostics and optional manual rate override.
    ///
    /// Runs the pipeline at both the primary (5 kHz) and alternate (8 kHz)
    /// highpass cutoffs and returns whichever gives higher quality. The
    /// alternate pass reuses the primary's rate decision (knownRate) so it
    /// only needs to re-do tick extraction — much cheaper than a full second
    /// pipeline run. The rate identification happens at the primary cutoff.
    public func measureWithDiagnostics(_ input: AudioBuffer, knownRate: StandardBeatRate? = nil) -> (MeasurementResult, PipelineDiagnostics) {
        let primary = measureAtCutoff(input, cutoff: Self.highpassCutoffHz, knownRate: knownRate)

        // Re-run at alternate cutoff using the primary's identified rate.
        // If the alternate pass produces a higher-quality tick extraction
        // (cleaner residuals on the same rate), prefer it.
        let alternateRate = knownRate ?? primary.0.snappedRate
        let alternate = measureAtCutoff(input, cutoff: Self.alternateHighpassCutoffHz, knownRate: alternateRate)

        if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_DUALHP"] != nil {
            FileHandle.standardError.write("[dualHP] primary=\(primary.0.snappedRate.rawValue)bph q=\(Int(primary.0.qualityScore*100))% | alternate=\(alternate.0.snappedRate.rawValue)bph q=\(Int(alternate.0.qualityScore*100))% -> pick \(alternate.0.qualityScore > primary.0.qualityScore ? "alternate" : "primary")\n".data(using: .utf8)!)
        }

        return alternate.0.qualityScore > primary.0.qualityScore ? alternate : primary
    }

    /// Run the pipeline at a specific highpass cutoff.
    private func measureAtCutoff(_ input: AudioBuffer, cutoff: Double, knownRate: StandardBeatRate?) -> (MeasurementResult, PipelineDiagnostics) {
        let sampleRate = input.sampleRate
        let samples = conditioner.highpassFilter(input.samples, sampleRate: sampleRate, cutoff: cutoff)
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
        // If the caller specified a known rate, use it directly. Otherwise
        // always try every standard rate — the per-rate fit scoring below is
        // what actually picks the winner, and it catches harmonic confusion
        // that an FFT-magnitude-only shortcut would miss.
        let candidateRates: [StandardBeatRate] = knownRate.map { [$0] } ?? StandardBeatRate.allCases

        var bestTickResult: TickExtractionResult?
        var bestRate = knownRate ?? rateScores.first?.rate ?? StandardBeatRate.bph28800
        // Separate tickTimings for amplitude estimation. Usually the same as
        // the display timings, but in the tiebreak path they differ (see below).
        var amplitudeTickTimings: [TickTiming]? = nil

        // Score every candidate, then pick the winner with a harmonic-aware rule.
        struct CandidateResult {
            let rate: StandardBeatRate
            let tickResult: TickExtractionResult
            let score: Double
            let recoveryRate: Double
            let envMag: Float
        }
        var candidates: [CandidateResult] = []

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

            // Period consistency: penalize if measured period is far from nominal.
            // Tolerance is 5% (≈4300 s/day) — wide enough to accept badly-worn
            // movements running far off rate (Tim's SickWatch sits at ~4.8% drift)
            // while still punishing the pseudo-periods that wrong harmonics
            // produce when they lock onto reverb or sub-clicks rather than real
            // ticks. Residual quality and env magnitude catch those cases.
            let periodConsistency: Double
            if let measuredPeriod = tickResult.measuredPeriod {
                let periodDeviation = abs(measuredPeriod - rate.nominalPeriodSeconds) / rate.nominalPeriodSeconds
                periodConsistency = exp(-periodDeviation / 0.05)
            } else {
                periodConsistency = 0.0
            }

            // Envelope FFT magnitude as primary tiebreak between rates that all
            // fit the time domain. A watch's true fundamental dominates the
            // envelope spectrum; pseudo-harmonics at other rates produce ticks
            // but weaker envelope peaks. Weighting env magnitude fully (instead
            // of the old 0.5 + 0.5·env blend) lets the FFT override time-domain
            // fit when multiple rates pass — e.g. on sick watches where a wrong
            // harmonic locks onto reverb at a cleaner period than the true rate.
            let envMag = rateScores.first(where: { $0.rate == rate })?.magnitude ?? 0
            let maxEnvMag = rateScores.first?.magnitude ?? 1
            let envBoost = maxEnvMag > 0 ? Double(envMag / maxEnvMag) : 0

            let score = recoveryRate * residualQuality * periodConsistency * envBoost

            candidates.append(CandidateResult(rate: rate, tickResult: tickResult, score: score, recoveryRate: recoveryRate, envMag: envMag))
        }

        // Initial winner: highest time-domain fit score.
        var tiebreakFired = false
        if let top = candidates.max(by: { $0.score < $1.score }) {
            bestRate = top.rate
            bestTickResult = top.tickResult

            // Harmonic-preference tiebreak.
            // Some ticks contain secondary audible events at a sub-period (e.g. a
            // rebound or echo ~100 ms after the main click on 18000 bph Timexes).
            // When mic placement captures the secondary strongly, a 2× rate can
            // fit the time domain better than the true fundamental — its
            // regression period locks cleanly to the sub-period while the
            // fundamental's regression drifts. The envelope FFT still sees the
            // fundamental as the dominant bin. Use that spectral evidence to
            // override when the candidate at winner.hz/2 has a strictly larger
            // envelope FFT magnitude than the winner. A true higher-rate watch
            // with asymmetric tick/tock strength can produce some sub-harmonic
            // energy, but the fundamental (at the actual rate) always dominates
            // the envelope FFT for real bi-pulse escapements — so any file with
            // envMag@lower > envMag@winner is evidence of harmonic confusion.
            //
            // We deliberately do NOT gate on the candidate's own fit score or
            // recovery rate: the failure mode we are trying to catch is exactly
            // where the lower rate's fit collapses (confused picker alternating
            // between tick and sub-click), which would make any threshold on
            // its own numbers reject the very case we want to swap. The safety
            // comes from reusing the *winner's* clean ticks reinterpreted at 2×
            // period, not from anything the lower rate's own fit produced.
            //
            // Only exact 2× relationships among standard rates trigger this
            // (currently 18000 ↔ 36000 is the only pair).
            let winnerHz = top.rate.hz
            for cand in candidates where cand.rate != top.rate {
                let ratio = winnerHz / cand.rate.hz
                guard abs(ratio - 2.0) < 0.01 else { continue }  // winner is 2× candidate
                guard top.envMag > 0 else { continue }
                let envRatio = Double(cand.envMag / top.envMag)
                if envRatio > 1.0 {
                    // Classify as the lower rate, but reuse the winner's clean
                    // tick data reinterpreted at the lower rate. The winner's
                    // regression locked to the sub-period (e.g. 100 ms), so the
                    // true main-tick period is exactly 2× that. Beat error is
                    // not meaningful here: the winner's even/odd split captures
                    // main-tick-vs-sub-pulse asymmetry, not tick-vs-tock.
                    bestRate = cand.rate
                    if let subPeriod = top.tickResult.measuredPeriod {
                        let doubledPeriod = subPeriod * 2.0
                        bestTickResult = TickExtractionResult(
                            confirmedCount: top.tickResult.confirmedCount,
                            qualityScore: top.tickResult.qualityScore,
                            beatErrorMs: nil,
                            amplitudeProxy: top.tickResult.amplitudeProxy,
                            measuredPeriod: doubledPeriod,
                            residualStd: top.tickResult.residualStd,
                            tickTimings: top.tickResult.tickTimings
                        )
                        // Amplitude needs tickTimings whose beatIndex is
                        // spaced at the reported rate's period. The winner's
                        // timings are at 2× rate and would throw the
                        // phase-aligned fold off by 2×. Fall back to the
                        // candidate's own timings (fewer, but correctly
                        // spaced at the 18000 beat).
                        amplitudeTickTimings = cand.tickResult.tickTimings
                    } else {
                        bestTickResult = cand.tickResult
                    }
                    tiebreakFired = true
                    break
                }
            }


            // Orderliness fallback. On watches where two rates have nearly-
            // identical envelope FFT magnitudes, the multiplicative score can
            // flip to the wrong rate even though the resulting timegraph shows
            // scrambled tick/tock parities. Check whether the winner's parities
            // are orderly (one-sided distribution relative to zero on at least
            // one parity — the other may straddle if the regression center is
            // slightly off). If the winner is scrambled, walk rates from
            // lowest to highest and pick the first rate whose tick/tock
            // distribution is orderly, even if quality is poor. Skipped when
            // the harmonic tiebreak fired or when the caller pinned a rate.
            if !tiebreakFired, candidateRates.count > 1,
               let top = candidates.max(by: { $0.score < $1.score }),
               top.tickResult.qualityScore < 0.30,
               let current = bestTickResult, !isOrderly(timings: current.tickTimings) {
                let others = candidates
                    .filter { $0.rate != bestRate }
                    .sorted { $0.rate.hz < $1.rate.hz }
                if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_ORDER"] != nil {
                    FileHandle.standardError.write("[orderly] winner=\(bestRate.rawValue) scrambled; trying others low→high\n".data(using: .utf8)!)
                    for c in others {
                        let ok = isOrderly(timings: c.tickResult.tickTimings)
                        FileHandle.standardError.write("[orderly]   \(c.rate.rawValue): orderly=\(ok)\n".data(using: .utf8)!)
                    }
                }
                for cand in others where isOrderly(timings: cand.tickResult.tickTimings) {
                    bestRate = cand.rate
                    bestTickResult = cand.tickResult
                    break
                }
            }
        }

        var tickResult = bestTickResult ?? TickExtractionResult(
            confirmedCount: 0, qualityScore: 0, beatErrorMs: nil, amplitudeProxy: 0,
            measuredPeriod: nil, residualStd: .infinity, tickTimings: []
        )

        // Re-walk the winner using the regression-derived period from the
        // initial nominal-period walk. With a fixed nominal period, watches
        // with > ±200 s/day rate error see beats drift past the picker's
        // ±20 ms search window at the start and end of the recording; the
        // picker silently drops them. Re-walking at the actual period keeps
        // every beat near its window center across the full 15 s.
        //
        // We use the regression slope (not the envelope FFT period) because
        // on sick pin-lever Timexes the FFT can have a dominant peak 4-5%
        // off the true tick rate. The regression is computed from actual
        // confirmed tick positions in the time domain, so it accurately
        // reflects what the watch is doing — even when the FFT doesn't.
        //
        // Skipped when the harmonic tiebreak fired (the tick data is
        // already from a different rate's walk).
        if !tiebreakFired,
           tickResult.confirmedCount >= 10,
           let regSlope = tickResult.measuredPeriod, regSlope > 0 {
            let nominalPeriod = bestRate.nominalPeriodSeconds
            let usableLength = Double(samples.count) / sampleRate
            let totalBeats = usableLength / nominalPeriod
            let driftAcrossRecording = totalBeats * abs(regSlope - nominalPeriod)
            let searchHalfWidth = 0.040
            if driftAcrossRecording > searchHalfWidth,
               ProcessInfo.processInfo.environment["WATCHBEAT_NO_REWALK"] == nil {
                let rewalked = extractTicks(
                    samples: samples, sampleRate: sampleRate,
                    rate: bestRate, measuredHz: 1.0 / regSlope,
                    walkPeriodOverride: regSlope
                )
                if rewalked.confirmedCount >= tickResult.confirmedCount {
                    tickResult = rewalked
                }
            }
        }

        // Alignment selection by tick/tock orderliness. The picker can
        // produce different slopes at different startOffsets — sometimes
        // dramatically (Timex1CrownUp shifts +84 s/day depending on which
        // alignment is chosen). When the alignment "best by confirmedCount"
        // (current default) gives scrambled tick/tock labels (residuals
        // straddling zero in both parities), an alternative alignment may
        // produce cleanly alternating labels with the watch's actual BE
        // visible. Orderliness — fraction of residuals on the dominant
        // side of zero, per parity — flags this directly: scrambled ≈ 0.5,
        // clean ≈ 1.0. Pick the alignment with highest orderliness across
        // 8 startOffsets; the picker's confirmedCount-based choice was
        // already considered (it's one of the 5 in the existing search).
        // Skipped when harmonic tiebreak fired.
        if !tiebreakFired,
           tickResult.confirmedCount >= 10,
           let baseSlope = tickResult.measuredPeriod, baseSlope > 0,
           ProcessInfo.processInfo.environment["WATCHBEAT_NO_ORDERSEL"] == nil {
            let candidates = extractTicksAcrossOffsets(
                samples: samples, sampleRate: sampleRate,
                rate: bestRate, measuredHz: 1.0 / baseSlope,
                walkPeriodOverride: baseSlope, numOffsets: 8
            )
            // Score each candidate by orderliness. Combine with confirmed
            // count as a tie-breaker (more ticks is better at equal
            // orderliness). Only swap if we find a clearly better one.
            func orderlinessScore(_ r: TickExtractionResult) -> Double {
                let even = r.tickTimings.filter { $0.isEvenBeat }.map { $0.residualMs }
                let odd = r.tickTimings.filter { !$0.isEvenBeat }.map { $0.residualMs }
                guard even.count >= 5, odd.count >= 5 else { return 0 }
                let oe = Self.oneSidedness(even)
                let oo = Self.oneSidedness(odd)
                return max(oe, oo)
            }
            // Conservative swap: only adopt a candidate if its orderliness
            // is decisively better (>0.15) AND clearly indicates clean
            // tick/tock structure (>0.85 absolute), AND it doesn't lose
            // significant confirmed-pick coverage or quality. This keeps
            // alignment-stable readings (TimexTickTick, Strong_Internal
            // when it's actually clean) untouched, only intervening when
            // the original alignment is genuinely scrambled.
            let baseScore = orderlinessScore(tickResult)
            var bestCand = tickResult
            var bestScore = baseScore
            for c in candidates {
                let s = orderlinessScore(c)
                guard s > 0.85 else { continue }
                guard s > bestScore + 0.15 else { continue }
                guard c.confirmedCount >= tickResult.confirmedCount * 3 / 4 else { continue }
                guard c.qualityScore >= tickResult.qualityScore * 0.8 else { continue }
                bestScore = s
                bestCand = c
            }
            tickResult = bestCand
        }


        // Apply matched-filter refinement to the WINNING rate's tick result.
        // This is the expensive step (~5–10 ms in release per call), so it
        // runs once after rate selection rather than for every candidate
        // × offset combination inside the rate-selection loop.
        if ProcessInfo.processInfo.environment["WATCHBEAT_SKIP_MF"] == nil {
            tickResult = applyMatchedFilter(
                to: tickResult, samples: samples, sampleRate: sampleRate, rate: bestRate
            )
        }

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
            tickCount: tickResult.confirmedCount,
            tickTimings: tickResult.tickTimings,
            amplitudeTickTimings: amplitudeTickTimings,
            isLowConfidence: tickResult.isLowConfidence,
            measuredPeriod: tickResult.measuredPeriod,
            regressionIntercept: tickResult.regressionIntercept
        )

        let bestMeasuredHz = tickResult.measuredPeriod.map { 1.0 / $0 } ?? bestRate.hz
        let periodEstimate = PeriodEstimate(
            measuredHz: bestMeasuredHz, snappedRate: bestRate, confidence: confidence
        )

        let diagnostics = PipelineDiagnostics(
            rawPeakAmplitude: input.samples.map { abs($0) }.max() ?? 0,
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
    /// Window is ±0.5 Hz — intentionally wide so adjacent rates score similarly,
    /// which triggers the more thorough try-all-rates path with tick extraction.
    /// (The FrequencyMonitor display uses ±0.2 Hz to avoid visual overlap.)
    private func peakMagnitudeNear(magnitudes: [Float], freqResolution: Double, hz: Double) -> Float {
        let targetBin = Int(round(hz / freqResolution))
        let windowRadius = max(1, Int(ceil(0.5 / freqResolution)))
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
        let residualStd: Double
        /// Tick timings for the timegrapher plot.
        let tickTimings: [TickTiming]
        /// Lock-in centroid times in seconds, indexed by beat number.
        /// Used by the post-rate-selection matched-filter refinement to
        /// reconstruct absolute tick positions without needing the squared
        /// signal to be carried through.
        var peakTimes: [Double] = []
        /// Beat indices of confirmed ticks (parallel selection into peakTimes).
        var confirmed: [Int] = []
        /// Lock-in regression intercept (seconds). Combined with measuredPeriod
        /// gives `predicted = slope * beatIndex + intercept`.
        var regressionIntercept: Double? = nil
        /// True when matched-filter trim survival was below threshold.
        /// Set only by the post-selection refinement; defaults to false.
        var isLowConfidence: Bool = false
    }

    /// Divide the raw signal into beat-length windows, find energy peaks.
    /// Tries two window offsets (0 and half-period) to avoid the boundary problem
    /// where ticks landing near window edges split their energy and get missed.
    private func extractTicks(
        samples: [Float], sampleRate: Double,
        rate: StandardBeatRate, measuredHz: Double,
        walkPeriodOverride: Double? = nil
    ) -> TickExtractionResult {
        let n = samples.count
        // Use the candidate rate's nominal period for window sizing during
        // rate-selection scoring. On sick pin-lever Timexes the envelope FFT
        // can have a dominant peak 4-5% off the true tick rate (spurious extra
        // impulses create a fake-rate peak). Letting measuredHz drive window
        // size makes every candidate rate lock onto that same fake pattern,
        // so all candidates yield the same off-rate slope and the scorer
        // picks the rate whose nominal is closest to the fake — usually
        // wrong. Using the nominal period means each candidate gets tested
        // on ITS terms: the true rate finds real ticks, wrong candidates fail.
        //
        // After rate selection picks a winner, the caller can pass
        // `walkPeriodOverride` to re-extract with windows aligned to the
        // watch's actual period. That avoids boundary-cutoff dropouts at the
        // start/end of the recording on watches with large rate errors
        // (>200 s/day at 18000 bph) where ticks would otherwise drift past
        // the search window's ±20 ms half-width.
        let period = walkPeriodOverride ?? rate.nominalPeriodSeconds
        let periodSamples = Int(round(period * sampleRate))

        guard periodSamples > 10 && periodSamples < n / 3 else {
            return TickExtractionResult(confirmedCount: 0, qualityScore: 0,
                                        beatErrorMs: nil, amplitudeProxy: 0, measuredPeriod: nil, residualStd: .infinity, tickTimings: [])
        }

        // Squared signal for energy measurement
        var squared = [Float](repeating: 0, count: n)
        vDSP_vsq(samples, 1, &squared, 1, vDSP_Length(n))

        // Smoothed energy for coarse tick *location* only. A raw squared signal
        // has fine sub-peak structure — the escapement click often contains two
        // energy events ~3-5 ms apart (unlock impulse + rebound / secondary
        // drop on worn movements). Argmax on raw squared picks whichever
        // sub-peak happens to be louder in each tick; when that flips between
        // sub-peaks across the recording the whole tick/tock pattern inverts
        // mid-run and the regression slope warps. Argmax on a 5 ms centered
        // moving-average of the squared signal gives one stable coarse peak
        // per tick regardless of sub-peak balance. The actual sub-sample tick
        // time is then the centroid of the *raw* squared within ±5 ms of that
        // peak (see `extractTicksAtOffset` for why we don't centroid the
        // smoothed signal — it plateaus and biases rate). Window is forced odd
        // for centering.
        let smoothed = movingAverage(of: squared, windowSamples: max(3, Int(0.005 * sampleRate)) | 1)

        // Try 5 evenly spaced starting offsets across one period.
        // With 5 offsets, no tick can be closer than 1/10 of a period from the
        // nearest window center. Pick whichever offset finds the most confirmed ticks.
        let numOffsets = 5
        var bestResult = TickExtractionResult(confirmedCount: 0, qualityScore: 0,
                                               beatErrorMs: nil, amplitudeProxy: 0,
                                               measuredPeriod: nil, residualStd: .infinity, tickTimings: [])

        for k in 0..<numOffsets {
            let offset = k * periodSamples / numOffsets
            let result = extractTicksAtOffset(
                squared: squared, smoothed: smoothed, n: n, sampleRate: sampleRate, rate: rate,
                periodSamples: periodSamples, startOffset: offset
            )
            if result.confirmedCount > bestResult.confirmedCount {
                bestResult = result
            }
        }

        return bestResult
    }

    /// Run the picker at N evenly spaced startOffsets across one period,
    /// returning all results (not just the max-confirms one). Used by the
    /// alignment-sensitivity test: a watch whose true rate is well-determined
    /// by the audio gives nearly identical slopes regardless of startOffset;
    /// a marginal sick watch can show large slope spread across alignments.
    private func extractTicksAcrossOffsets(
        samples: [Float], sampleRate: Double,
        rate: StandardBeatRate, measuredHz: Double,
        walkPeriodOverride: Double? = nil,
        numOffsets: Int
    ) -> [TickExtractionResult] {
        let n = samples.count
        let period = walkPeriodOverride ?? rate.nominalPeriodSeconds
        let periodSamples = Int(round(period * sampleRate))
        guard periodSamples > 10 && periodSamples < n / 3 else { return [] }

        var squared = [Float](repeating: 0, count: n)
        vDSP_vsq(samples, 1, &squared, 1, vDSP_Length(n))
        let smoothed = movingAverage(of: squared, windowSamples: max(3, Int(0.005 * sampleRate)) | 1)

        var results: [TickExtractionResult] = []
        results.reserveCapacity(numOffsets)
        for k in 0..<numOffsets {
            let offset = (k * periodSamples) / numOffsets
            let result = extractTicksAtOffset(
                squared: squared, smoothed: smoothed, n: n, sampleRate: sampleRate, rate: rate,
                periodSamples: periodSamples, startOffset: offset
            )
            results.append(result)
        }
        return results
    }

    /// Tick/tock orderliness test. Looks at the *distribution* of residuals
    /// for each parity relative to the regression center (residual = 0),
    /// not their means. In an orderly timegraph, tick residuals sit
    /// consistently on one side of zero and tock residuals on the other —
    /// the two parities form distinct horizontal lines. On a scrambled
    /// assignment (wrong rate, mixed tick/tock labeling), both parities
    /// straddle zero roughly 50/50 because the labels don't correspond to
    /// real tick/tock structure.
    ///
    /// A single parity straddling is tolerated — the regression center
    /// is a least-squares best fit, not the true tick midline, so one
    /// cluster may sit across zero even on a clean watch. Both parities
    /// straddling means the labels are carrying no tick/tock information.
    /// "Straddles" = dominant side holds < 75% of the parity's samples.
    private func isOrderly(timings: [TickTiming]) -> Bool {
        let even = timings.filter { $0.isEvenBeat }.map { $0.residualMs }
        let odd = timings.filter { !$0.isEvenBeat }.map { $0.residualMs }
        guard even.count >= 5, odd.count >= 5 else { return false }
        let straddlesE = Self.oneSidedness(even) < Self.orderlinessThreshold
        let straddlesO = Self.oneSidedness(odd) < Self.orderlinessThreshold
        return !(straddlesE && straddlesO)
    }

    /// Advisory flag for the UI: the matched filter had to drop too many
    /// ticks to trust the result. The watch itself isn't disorderly —
    /// escapements are mechanically deterministic. This flag means the
    /// recording was acoustically complex enough (multiple comparable
    /// sub-events, weak signal, sub-event flipping, etc.) that the picker
    /// couldn't lock on consistently. Caller routes this to a "low
    /// confidence" retry screen rather than showing a number.
    ///
    /// On the OmegaStudy corpus, healthy recordings retain 50–65% of
    /// confirmed ticks after matched-filter trim; the historical Timex2
    /// near-stall recordings retained ~26%. Threshold at 40% is well
    /// below the legitimate floor and well above genuine failure rates.
    private func isLowConfidenceByKeptFraction(kept: Int, confirmed: Int) -> Bool {
        guard confirmed >= 6 else { return false }
        return Double(kept) / Double(confirmed) < 0.40
    }

    /// Fraction of residuals on the dominant side of zero. 1.0 = all
    /// positive or all negative; 0.5 = perfect 50/50 split.
    private static func oneSidedness(_ xs: [Double]) -> Double {
        let pos = xs.filter { $0 > 0 }.count
        let frac = Double(pos) / Double(xs.count)
        return max(frac, 1 - frac)
    }

    private static let orderlinessThreshold: Double = 0.60

    /// Centered moving average with clamped edges. O(n) via running sum.
    /// Each output sample is the mean of `squared[max(0, i-half)...min(n-1, i+half)]`
    /// where `half = windowSamples / 2`. Window widths are tracked explicitly so
    /// edge samples are correctly averaged over their clipped window rather than
    /// biased by a fixed divisor.
    private func movingAverage(of x: [Float], windowSamples: Int) -> [Float] {
        let n = x.count
        guard windowSamples > 1, n > 0 else { return x }
        let half = windowSamples / 2
        var out = [Float](repeating: 0, count: n)
        var runSum: Float = 0
        var left = 0
        var right = -1
        while right + 1 <= min(n - 1, half) {
            right += 1
            runSum += x[right]
        }
        for i in 0..<n {
            let width = right - left + 1
            out[i] = width > 0 ? runSum / Float(width) : 0
            let nextRight = min(n - 1, i + 1 + half)
            while right < nextRight {
                right += 1
                runSum += x[right]
            }
            let nextLeft = max(0, i + 1 - half)
            while left < nextLeft {
                runSum -= x[left]
                left += 1
            }
        }
        return out
    }

    /// Centroid (first moment) of a segment of `y` with its minimum subtracted
    /// as a baseline. Returns absolute sub-sample position, or nil if the
    /// segment is flat (no energy above baseline). Baseline subtraction keeps
    /// the centroid locked to the energy peak rather than drifting toward the
    /// geometric window center when the signal has a noise floor.
    private func centroid(in y: [Float], lo: Int, hi: Int) -> Double? {
        guard lo <= hi, lo >= 0, hi < y.count else { return nil }
        var minVal = y[lo]
        for j in (lo + 1)...hi { if y[j] < minVal { minVal = y[j] } }
        var num: Double = 0
        var den: Double = 0
        for j in lo...hi {
            let w = Double(y[j] - minVal)
            if w > 0 {
                num += w * Double(j)
                den += w
            }
        }
        guard den > 0 else { return nil }
        return num / den
    }

    /// Extract ticks with windows starting at a specific offset.
    ///
    /// - Parameters:
    ///   - squared: Raw squared signal. Used for tick-energy / gap-energy
    ///     measurements (SNR and confirmation gating). Keeping this
    ///     un-smoothed preserves the sharp contrast between tick bursts and
    ///     quiet gaps, so quality scores stay accurate.
    ///   - smoothed: Moving-averaged squared signal. Used for *location*
    ///     only — argmax to pick the tick's search region and centroid for
    ///     sub-sample positioning. Smoothing merges multi-sub-peak tick
    ///     structure into one blob per tick; centroid then gives a stable
    ///     location even when sub-peaks swap dominance between beats.
    private func extractTicksAtOffset(
        squared: [Float], smoothed: [Float], n: Int, sampleRate: Double, rate: StandardBeatRate,
        periodSamples: Int, startOffset: Int
    ) -> TickExtractionResult {
        // Divide into windows from startOffset, find peak in each
        let usableLength = n - startOffset
        let numWindows = usableLength / periodSamples
        guard numWindows >= 3 else {
            return TickExtractionResult(confirmedCount: 0, qualityScore: 0,
                                        beatErrorMs: nil, amplitudeProxy: 0, measuredPeriod: nil, residualStd: .infinity, tickTimings: [])
        }

        var peakOffsets = [Int](repeating: 0, count: numWindows)

        for w in 0..<numWindows {
            let wStart = startOffset + w * periodSamples
            var bestIdx = 0
            var bestVal: Float = 0
            // Coarse medianOffset detection: use raw squared. The smoothed
            // signal buries dropout windows' noise spikes in averaged energy,
            // which can pull the median offset toward reverb-from-adjacent-tick
            // patterns that look stable at wrong offsets. Raw squared is more
            // random in empty windows, so its argmax distributes uniformly
            // and the median of many windows still reflects the true tick
            // offset from the majority of filled windows.
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

            // Tick location: argmax on *smoothed* to anchor the tick's coarse
            // position (smoothing merges sub-peaks so this doesn't flip
            // between them), then centroid on the *raw squared* signal within
            // a narrow window around that anchor for sub-sample precision.
            // Smoothing the squared signal and then centroiding it has a
            // plateau problem when the smoothing window exceeds the tick
            // duration (the smoothed bump flat-tops); centroiding the raw
            // squared signal avoids that while still being stable under
            // sub-peak flipping — the centroid of a multi-peak tick is the
            // amplitude-weighted average of its sub-peak positions, which
            // shifts gradually with sub-peak balance instead of jumping.
            var peakIdx = 0
            var peakVal: Float = 0
            for i in 0..<tickWindow {
                if smoothed[wStart + i] > peakVal {
                    peakVal = smoothed[wStart + i]
                    peakIdx = i
                }
            }
            let absPeak = wStart + peakIdx
            let cHalf = max(4, Int(0.005 * sampleRate))
            let cLo = max(0, absPeak - cHalf)
            let cHi = min(n - 1, absPeak + cHalf)
            if let c = centroid(in: squared, lo: cLo, hi: cHi) {
                peakTimes.append(c / sampleRate)
            } else {
                peakTimes.append(Double(absPeak) / sampleRate)
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
                                        beatErrorMs: nil, amplitudeProxy: 0, measuredPeriod: nil, residualStd: .infinity, tickTimings: [])
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
                                        beatErrorMs: nil, amplitudeProxy: 0, measuredPeriod: nil, residualStd: .infinity, tickTimings: [])
        }

        // Quality from SNR
        let medianTick = sortedMedian(tickEnergies.map { $0 })
        let snr = medianGap > 0 ? Double(medianTick / medianGap) : 100.0
        let quality = min(1.0, max(0.0, 1.0 - exp(-snr / 5.0)))

        // Regression on confirmed tick peak positions
        var regression = linearRegression(times: peakTimes, indices: confirmed)

        // Lock-in pass: re-pick each confirmed tick as the centroid of raw
        // squared energy in a narrow window around the regression-predicted
        // time, then refit. Centroid is used (not argmax) for the same reason
        // as the first pass — stability under sub-peak flipping. Window is
        // ±5 ms, wide enough to span a multi-sub-peak tick cluster so the
        // centroid sees the full blob.
        if confirmed.count >= 10, let slope = regression.slope, let intercept = regression.intercept, slope > 0 {
            let lockHalf = max(4, Int(0.005 * sampleRate))
            for i in confirmed {
                let predicted = slope * Double(i) + intercept
                let centerSample = Int(round(predicted * sampleRate))
                let lo = max(0, centerSample - lockHalf)
                let hi = min(n - 1, centerSample + lockHalf)
                guard lo < hi else { continue }
                if let c = centroid(in: squared, lo: lo, hi: hi) {
                    peakTimes[i] = c / sampleRate
                }
            }
            regression = linearRegression(times: peakTimes, indices: confirmed)
        }

        // Lock-in BE for now — the matched-filter refinement is too
        // expensive to run inside the rate-selection loop (which calls
        // extractTicksAtOffset 6 rates × 5 offsets = 30× per analysis
        // pass). The production-quality matched-filter pass runs ONCE on
        // the winning rate after rate selection completes, in
        // `applyMatchedFilter`.
        let beatError: Double?
        if !rate.isQuartz && confirmed.count >= 6, let slope = regression.slope, let intercept = regression.intercept {
            var residualByBeat: [Int: Double] = [:]
            for i in confirmed {
                let predicted = slope * Double(i) + intercept
                residualByBeat[i] = peakTimes[i] - predicted
            }
            beatError = BeatError.meanPairedAbsDifference(residualsByBeat: residualByBeat).map { $0 * 1000.0 }
        } else {
            beatError = nil
        }

        var timings: [TickTiming] = []
        if let slope = regression.slope, let intercept = regression.intercept {
            for i in confirmed {
                guard i < peakTimes.count else { continue }
                let predicted = slope * Double(i) + intercept
                let residualMs = (peakTimes[i] - predicted) * 1000.0
                timings.append(TickTiming(beatIndex: i, residualMs: residualMs, isEvenBeat: i % 2 == 0))
            }
        }

        return TickExtractionResult(
            confirmedCount: confirmed.count,
            qualityScore: quality,
            beatErrorMs: beatError,
            amplitudeProxy: Double(medianTick),
            measuredPeriod: regression.slope,
            residualStd: regression.residualStd,
            tickTimings: timings,
            peakTimes: peakTimes,
            confirmed: confirmed,
            regressionIntercept: regression.intercept,
            isLowConfidence: false
        )
    }

    /// Apply matched-filter refinement to a tick extraction result. Runs
    /// MatchedFilterRefinement.refinePositions on the lock-in tick
    /// positions, then rebuilds beatErrorMs / tickTimings / isLowConfidence
    /// from the survivors. Used after rate selection so the heavy work
    /// runs ONCE on the winner instead of every candidate × offset.
    private func applyMatchedFilter(
        to tickResult: TickExtractionResult,
        samples: [Float],
        sampleRate: Double,
        rate: StandardBeatRate
    ) -> TickExtractionResult {
        guard !rate.isQuartz, tickResult.confirmed.count >= 6,
              let slope = tickResult.measuredPeriod,
              let intercept = tickResult.regressionIntercept else {
            return tickResult
        }
        // Squared signal is what MatchedFilterRefinement consumes — recompute
        // for the winner only (single O(n) vDSP_vsq, ~1 ms for 15 s @ 48 kHz).
        var squared = [Float](repeating: 0, count: samples.count)
        vDSP_vsq(samples, 1, &squared, 1, vDSP_Length(samples.count))

        // Rescue pass on the rate-selection winner: walk every beat slot the
        // regression covers and try to recover ticks the per-window energy
        // threshold rejected. The first-pass gate (`tickEnergy > 2 × medianGap`)
        // fails on bursty recordings — a loud cluster pulls medianGap up and
        // quiet real ticks elsewhere drop below threshold (e.g. Timex3Weak
        // crown-up loses ~50 of 75 beats this way). With slope/intercept now
        // locked from the rate winner's confirmed beats, we know exactly where
        // each missing tick should land. Accept a slot if its local peak
        // (smoothed envelope max in ±10 ms of predicted center) is at least
        // 30 % of the median local peak among already-confirmed beats — i.e.
        // its peak is comparable in magnitude to a typical tick on this watch.
        // Centroid at the predicted center (not at the local argmax) so the
        // recovered position matches the regression-aligned sub-event the
        // confirmed ticks already encode — argmax-driven centroid would bias
        // toward whichever sub-event happens to be loudest in this slot,
        // warping the slope on multi-sub-event watches (Timex pin-levers,
        // Omegas). Runs only here, after rate-selection — so wrong-rate
        // candidates can't be lifted to win by spurious rescue.
        var rescuedConfirmed = tickResult.confirmed
        var rescuedPeakTimes = tickResult.peakTimes
        var rescuedSlope = slope
        var rescuedIntercept = intercept
        if tickResult.confirmed.count >= 10,
           tickResult.residualStd < 0.01,
           slope > 0 {
            let smoothWin = max(3, Int(0.005 * sampleRate)) | 1
            let smoothed = movingAverage(of: squared, windowSamples: smoothWin)
            let n = squared.count
            let gateHalf = max(8, Int(0.010 * sampleRate))
            let centroidHalf = max(4, Int(0.005 * sampleRate))
            var confirmedPeaks: [Float] = []
            confirmedPeaks.reserveCapacity(tickResult.confirmed.count)
            for i in tickResult.confirmed {
                let predicted = slope * Double(i) + intercept
                let centerSample = Int(round(predicted * sampleRate))
                let lo = max(0, centerSample - gateHalf)
                let hi = min(n - 1, centerSample + gateHalf)
                guard lo < hi else { continue }
                var mx: Float = 0
                for j in lo...hi { if smoothed[j] > mx { mx = smoothed[j] } }
                confirmedPeaks.append(mx)
            }
            if confirmedPeaks.count >= 10 {
                let medianConfirmedPeak = sortedMedian(confirmedPeaks)
                let rescueThreshold = medianConfirmedPeak * 0.3
                let confirmedSet = Set(tickResult.confirmed)
                let totalSlots = tickResult.peakTimes.count
                var rescuedSlots: [Int] = []
                for i in 0..<totalSlots {
                    if confirmedSet.contains(i) { continue }
                    let predicted = slope * Double(i) + intercept
                    let centerSample = Int(round(predicted * sampleRate))
                    let gLo = max(0, centerSample - gateHalf)
                    let gHi = min(n - 1, centerSample + gateHalf)
                    guard gLo < gHi else { continue }
                    var mx: Float = 0
                    var argmax = gLo
                    for j in gLo...gHi {
                        if smoothed[j] > mx { mx = smoothed[j]; argmax = j }
                    }
                    if mx < rescueThreshold { continue }
                    // Centroid in ±5 ms of the argmax (not the regression
                    // prediction). Asymmetric tick/tock geometry means real
                    // tocks can sit several ms off half-period; centroiding
                    // at the predicted center misses most of their energy.
                    // Mirrors the first-pass picker's argmax → centroid pattern.
                    let cLo = max(0, argmax - centroidHalf)
                    let cHi = min(n - 1, argmax + centroidHalf)
                    guard cLo < cHi else { continue }
                    if let c = centroid(in: squared, lo: cLo, hi: cHi) {
                        rescuedPeakTimes[i] = c / sampleRate
                        rescuedSlots.append(i)
                    }
                }
                if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_RESCUE"] != nil {
                    FileHandle.standardError.write("[rescue] confirmed=\(tickResult.confirmed.count) slots=\(totalSlots) medianPeak=\(medianConfirmedPeak) threshold=\(rescueThreshold) rescued=\(rescuedSlots.count)\n".data(using: .utf8)!)
                }
                if !rescuedSlots.isEmpty {
                    rescuedConfirmed.append(contentsOf: rescuedSlots)
                    rescuedConfirmed.sort()
                    let r = linearRegression(times: rescuedPeakTimes, indices: rescuedConfirmed)
                    if let s = r.slope, let icpt = r.intercept {
                        rescuedSlope = s
                        rescuedIntercept = icpt
                    }
                }
            }
        }

        let confirmedTimes = rescuedConfirmed.map { rescuedPeakTimes[$0] }
        let refined = MatchedFilterRefinement.refinePositions(
            squared: squared,
            sampleRate: sampleRate,
            tickPositions: confirmedTimes,
            beatIndices: rescuedConfirmed
        )
        // Build per-beatIndex map of refined positions.
        var refinedByBeat: [Int: Double] = [:]
        for (k, idx) in rescuedConfirmed.enumerated() {
            if let r = refined[k] { refinedByBeat[idx] = r }
        }
        let keptCount = refinedByBeat.count

        // Refit regression on lock-in positions of survivors so the
        // regression reflects only the well-locked ticks.
        var keptRegression: (slope: Double?, intercept: Double?) = (rescuedSlope, rescuedIntercept)
        let kept = rescuedConfirmed.filter { refinedByBeat[$0] != nil }
        if kept.count >= 6 {
            let r = linearRegression(times: rescuedPeakTimes, indices: kept)
            keptRegression = (r.slope, r.intercept)
        }

        // Pair-abs BE on lock-in residuals of survivors — matched filter
        // is the outlier gate; BE numbers come from lock-in.
        let beatError: Double?
        if let s = keptRegression.slope, let i = keptRegression.intercept {
            var residualByBeat: [Int: Double] = [:]
            for idx in rescuedConfirmed where refinedByBeat[idx] != nil {
                let predicted = s * Double(idx) + i
                residualByBeat[idx] = rescuedPeakTimes[idx] - predicted
            }
            beatError = BeatError.meanPairedAbsDifference(residualsByBeat: residualByBeat).map { $0 * 1000.0 }
        } else { beatError = nil }

        // Survivor-only tickTimings from the refit regression.
        var timings: [TickTiming] = []
        if let s = keptRegression.slope, let i = keptRegression.intercept {
            for idx in rescuedConfirmed where refinedByBeat[idx] != nil {
                let predicted = s * Double(idx) + i
                let residualMs = (rescuedPeakTimes[idx] - predicted) * 1000.0
                timings.append(TickTiming(beatIndex: idx, residualMs: residualMs, isEvenBeat: idx % 2 == 0))
            }
        }

        let lowConf = isLowConfidenceByKeptFraction(
            kept: keptCount, confirmed: rescuedConfirmed.count
        )

        return TickExtractionResult(
            confirmedCount: rescuedConfirmed.count,
            qualityScore: tickResult.qualityScore,
            beatErrorMs: beatError,
            amplitudeProxy: tickResult.amplitudeProxy,
            measuredPeriod: keptRegression.slope ?? tickResult.measuredPeriod,
            residualStd: tickResult.residualStd,
            tickTimings: timings,
            peakTimes: rescuedPeakTimes,
            confirmed: rescuedConfirmed,
            regressionIntercept: keptRegression.intercept ?? tickResult.regressionIntercept,
            isLowConfidence: lowConf
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
