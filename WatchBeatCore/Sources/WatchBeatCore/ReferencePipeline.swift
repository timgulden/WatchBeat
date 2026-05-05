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
        var filtered = conditioner.highpassFilter(input.samples, sampleRate: sampleRate, cutoff: Self.highpassCutoffHz)
        let n = filtered.count

        // Impulse suppression — two-tier:
        //   Tier 1 (clip at 100× median |signal|): clamp peak amplitude
        //     of any sample exceeding the threshold to ±clipLevel.
        //     Real ticks routinely exceed 100× and survive clipping
        //     (the post-clip squared envelope still shows a peak at
        //     the tick); zeroing real ticks instead breaks rate
        //     identification.
        //   Tier 2 (region excise for long clip clusters): for clip
        //     clusters whose span exceeds 3 ms, zero ±5 ms with a
        //     0.5 ms cosine taper. Real ticks have brief clip clusters
        //     (<2 ms span); flicks/bumps span ≥ 3 ms — the threshold
        //     separates them. The 7 ms threshold this replaces was
        //     leaving short flicks (like the 3 fingernail flicks on
        //     Seagull11) un-excised, where their clipped plateau in
        //     the squared envelope was winning argmax over real ticks.
        //
        // The taper at excision edges avoids fresh spectral artifacts
        // from sharp zero-to-signal transitions.
        let absVals = filtered.map { abs($0) }.sorted()
        let medianAbs = absVals[absVals.count / 2]
        if medianAbs > 0 {
            let clipLevel = 100 * medianAbs

            // Pass 1: clip individual samples > 100× median, collect
            // clipped positions.
            var clipPositions: [Int] = []
            for i in 0..<n {
                if filtered[i] > clipLevel {
                    clipPositions.append(i)
                    filtered[i] = clipLevel
                } else if filtered[i] < -clipLevel {
                    clipPositions.append(i)
                    filtered[i] = -clipLevel
                }
            }

            // Pass 2 (count-adaptive region excise): cluster clipped
            // positions that are within ~0.5 ms of each other (clipped
            // samples from the same physical event come in bursts at
            // the signal's oscillation period — gaps within an event
            // stay below 0.5 ms). For each cluster, measure span.
            //
            // Tick vs flick discrimination by WIDE-cluster count: pin-
            // lever Timex ticks span 3-7 ms when clipped (~15-80 wide
            // clusters per recording); modern Swiss ticks are brief,
            // <2 ms (zero wide clusters). Isolated flicks/bumps are
            // wide AND sparse (1-3 wide clusters). The wide-cluster
            // count cleanly separates these populations: < 10 wide
            // clusters means flicks (excise them); ≥ 10 means a wide-
            // tick watch (don't excise — they ARE the ticks).
            //
            // The 3 ms span threshold for "wide" was chosen because
            // Seagull-class Swiss ticks span <2 ms (so 3 ms safely
            // excludes them) and even narrow Timexes have >10 ticks
            // exceeding 3 ms (so the count gate fires correctly).
            let clusterGap = max(1, Int(0.0005 * sampleRate))
            let minImpulseSpan = max(1, Int(0.003 * sampleRate))
            var allClusters: [(start: Int, end: Int)] = []
            var clusterStart = -1
            var clusterEnd = -1
            for pos in clipPositions {
                if clusterStart < 0 {
                    clusterStart = pos
                    clusterEnd = pos
                } else if pos - clusterEnd <= clusterGap {
                    clusterEnd = pos
                } else {
                    allClusters.append((clusterStart, clusterEnd))
                    clusterStart = pos
                    clusterEnd = pos
                }
            }
            if clusterStart >= 0 {
                allClusters.append((clusterStart, clusterEnd))
            }

            // Wide-cluster count gate: count clusters that span ≥ 3 ms.
            // If fewer than 10, the wide clusters are sparse — they're
            // flicks/bumps in a recording where the watch's actual
            // ticks are brief (<3 ms span) and don't show up here.
            // Excise them. If ≥ 10, they're either pin-lever tick
            // events themselves or a wide-tick watch family — don't
            // excise (clip-at-threshold suffices).
            let wideClusters = allClusters.filter { $0.end - $0.start >= minImpulseSpan }
            var excisePositions: [Int] = []
            if wideClusters.count < 10 {
                for (s, e) in wideClusters {
                    excisePositions.append((s + e) / 2)
                }
            }

            if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_CLIP"] != nil {
                FileHandle.standardError.write("[clip] total_clusters=\(allClusters.count) wide(>=3ms)=\(wideClusters.count) excised=\(excisePositions.count)\n".data(using: .utf8)!)
            }

            // Build excision mask. mask[i] = 0 inside the core ±5 ms
            // around any excise position, ramping smoothly to 1 over a
            // 0.5 ms cosine taper outside. Multiplying filtered by the
            // mask both zeros the core and smooths the edges. min()
            // composition handles overlapping regions naturally.
            if !excisePositions.isEmpty {
                let excisionHalf = max(1, Int(0.005 * sampleRate))
                let rampN = max(1, Int(0.0005 * sampleRate))
                var mask = [Float](repeating: 1.0, count: n)
                for pos in excisePositions {
                    let coreLo = max(0, pos - excisionHalf)
                    let coreHi = min(n - 1, pos + excisionHalf)
                    for i in coreLo...coreHi { mask[i] = 0 }
                    let leftLo = max(0, coreLo - rampN)
                    if leftLo < coreLo {
                        for i in leftLo..<coreLo {
                            let t = Float(i - leftLo) / Float(coreLo - leftLo)
                            let m = 0.5 * (1 + cosf(.pi * t))  // 1 → 0
                            if m < mask[i] { mask[i] = m }
                        }
                    }
                    let rightHi = min(n - 1, coreHi + rampN)
                    if rightHi > coreHi {
                        for i in (coreHi + 1)...rightHi {
                            let t = Float(i - coreHi) / Float(rightHi - coreHi)
                            let m = 0.5 * (1 - cosf(.pi * t))  // 0 → 1
                            if m < mask[i] { mask[i] = m }
                        }
                    }
                }
                for i in 0..<n { filtered[i] *= mask[i] }
            }
        }

        // Squared + 1 ms boxcar smoothing (light — preserves peak location
        // without averaging adjacent sub-events).
        var squared = [Float](repeating: 0, count: n)
        vDSP_vsq(filtered, 1, &squared, 1, vDSP_Length(n))
        let smoothWin = max(3, Int(0.001 * sampleRate)) | 1
        let smoothed = movingAverage(of: squared, windowSamples: smoothWin)

        // Tried: Difference-of-Boxcars matched filter (single-scale and
        // multi-scale) to suppress broad noise events. Both correctly
        // preserved Seagull cases but regressed Timex2Odd (whose
        // multi-sub-event tick character spans wider than typical
        // Swiss/pin-lever ticks). Reverted — the impulse clipping above
        // captures the main robustness win without affecting any
        // watch's tick character. A proper FFT-based matched filter
        // with a watch-family-specific kernel would be the right next
        // step if more discrimination is needed.

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

            // ===== Heavy-rejection re-anchor + re-pick =====
            //
            // The initial picks above use FFT-anchored windows. When
            // isolated loud transients (flicks, bumps) contaminate a
            // recording, they bias the FFT peak — windows are placed at
            // the wrong cadence — and they produce huge-residual picks
            // wherever the loud event happened to land in a window. The
            // FFT-anchored slope through ALL initial picks is therefore
            // unreliable: a few flick picks can drag it off by tens of
            // s/day.
            //
            // Strategy:
            //   1. Coarse linear fit on ALL initial picks. The flick-
            //      contaminated picks have large residuals from this
            //      line; the real-tick picks have small residuals.
            //   2. Drop the worst 40% by absolute residual. Keep 60%.
            //      With 89 windows, 53 kept — plenty to define a line.
            //      40% gives margin to absorb several flicks plus near-
            //      flick contamination on a noisy recording.
            //   3. Re-fit the slope on the 60% kept. This slope follows
            //      the real-tick cadence, not the FFT-anchored cadence.
            //   4. Re-anchor windows at the refined slope/intercept and
            //      re-pick (pure argmax on smoothed envelope, same as
            //      initial pick — no template, no shape preference). With
            //      windows now at the right cadence, every window's real
            //      tick is centered, argmax lands on it.
            //
            // No template. No shape preference. The slope-by-rejection
            // step uses the rate ONLY to define windows, not to weight
            // pick positions.
            if m >= 10 {
                var sumI = 0.0, sumT = 0.0, sumII = 0.0, sumIT = 0.0
                for i in 0..<m {
                    let di = Double(i)
                    sumI += di; sumT += beatPositions[i]
                    sumII += di * di; sumIT += di * beatPositions[i]
                }
                let denom = Double(m) * sumII - sumI * sumI
                if abs(denom) > 1e-20 {
                    let slopeC = (Double(m) * sumIT - sumI * sumT) / denom
                    let interceptC = (sumT - slopeC * sumI) / Double(m)

                    // Drop worst 40% by absolute residual; keep best 60%.
                    var idxRes: [(idx: Int, absRes: Double)] = []
                    idxRes.reserveCapacity(m)
                    for i in 0..<m {
                        let pred = slopeC * Double(i) + interceptC
                        idxRes.append((i, abs(beatPositions[i] - pred)))
                    }
                    idxRes.sort { $0.absRes < $1.absRes }
                    let keepCount = max(6, (m * 60) / 100)
                    let keepers = idxRes.prefix(keepCount).map { $0.idx }

                    // Re-fit on the 60% kept.
                    var sIk = 0.0, sTk = 0.0, sIIk = 0.0, sITk = 0.0
                    for i in keepers {
                        let di = Double(i)
                        sIk += di; sTk += beatPositions[i]
                        sIIk += di * di; sITk += di * beatPositions[i]
                    }
                    let cmK = Double(keepers.count)
                    let denomK = cmK * sIIk - sIk * sIk
                    if abs(denomK) > 1e-20 {
                        let slopeR = (cmK * sITk - sIk * sTk) / denomK
                        let interceptR = (sTk - slopeR * sIk) / cmK

                        // Re-anchor windows at refined slope and re-pick
                        // (pure argmax on smoothed envelope — no template).
                        for w in 0..<m {
                            let tc = slopeR * Double(w) + interceptR
                            let centerSample = Int(round(tc * sampleRate))
                            let lo = max(0, centerSample - halfPeriodSamples)
                            let hi = min(n - 1, centerSample + halfPeriodSamples)
                            if lo >= hi { continue }
                            var bestIdx = lo
                            var bestVal: Float = -.infinity
                            for i in lo...hi {
                                if smoothed[i] > bestVal {
                                    bestVal = smoothed[i]; bestIdx = i
                                }
                            }
                            beatPositions[w] = Double(bestIdx) / sampleRate
                        }
                    }
                }
            }

            // OPT-IN: Robust-slope re-anchoring + two-pass noise rejection.
            //
            // Status (2026-05-04): prototype that catches some noise-
            // contaminated recordings (Seagull11 at conf 39% routes to
            // Weak Signal) but regresses muddyticks (conf 27%, wrong
            // rate selection). Currently disabled by default; enable via
            // WATCHBEAT_NOISE_REJECT=1 for A/B testing on saved
            // recordings. Algorithm overview:
            //
            //   1. Robust slope: regress all picks, drop worst 50% by
            //      residual, re-fit. For a noise-contaminated recording
            //      with <50% noise picks, the robust slope follows the
            //      real ticks (which fit a line) instead of noise
            //      (which scatters).
            //   2. Re-anchor windows at the robust slope + intercept.
            //   3. NoiseRejector: kill sub-boxes below 2× noise floor
            //      and positions appearing in <50% of windows.
            //   4. Re-pick from cleaned signal.
            //
            // Known limitation: when >50% of picks are noise, or the
            // noise is itself rhythmic at a different rate, the robust
            // slope locks onto the noise instead of the watch. Future
            // refinement needed before enabling by default.
            if ProcessInfo.processInfo.environment["WATCHBEAT_NOISE_REJECT"] != nil {
                let reAnchored = robustReAnchoredCenters(
                    initialPicks: beatPositions,
                    windowCount: m
                )
                let noiseRejector = NoiseRejector(
                    smoothed: smoothed,
                    sampleRate: sampleRate,
                    halfPeriodSamples: halfPeriodSamples
                )
                beatPositions = noiseRejector.clean(windowCenters: reAnchored)
            }

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

            // Beat error: mean of |tick_residual − tock_residual| across
            // adjacent (even, even+1) pairs. The previous formulation
            // |mean(even) − mean(odd)| reduced to ~0 on scattered residuals
            // (random scatter symmetric around zero on each class), giving
            // misleading sub-millisecond BE on watches where individual
            // pair differences are 10+ ms (Timex3Mess, 2026-05-05). MPAD
            // is the canonical formulation also used by the production
            // picker (see BeatError.meanPairedAbsDifference).
            var residualsByBeatSec: [Int: Double] = [:]
            for idx in cleanedConfirmed {
                residualsByBeatSec[idx] = residualsMs[idx] / 1000.0
            }
            let mpadMs = (BeatError.meanPairedAbsDifference(residualsByBeat: residualsByBeatSec) ?? 0) * 1000.0

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
                beAsymmetryMs: mpadMs,
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

        // Rate reporting: use the regression slope from cleaned-confirmed
        // picks. The slope is the average tick spacing in samples /
        // sampleRate — directly the tick cadence we want to report. The
        // FFT-derived fHz uses parabolic interpolation for sub-bin
        // precision and has a small but consistent bias on Hann-windowed
        // peaks (~0.03 bins ≈ 30-40 s/day at our 15 s window). On the
        // SeagullStudy this bias gave a -41 s/day offset vs the
        // timegrapher cluster; the regression slope agrees with the
        // timegrapher to ±2 s/day on the same recordings.
        //
        // The FFT remains essential for identifying which standard band
        // a recording belongs to, anchoring per-window centers, and the
        // high-σ fallback path below — but it is no longer the source of
        // the reported rate.
        let fftRateErrPerDay = (winner.fHz / snappedRate.hz - 1.0) * 86400.0
        let regRateErrPerDay = slope > 0
            ? ((1.0 / slope) / snappedRate.hz - 1.0) * 86400.0
            : fftRateErrPerDay
        let rateErrPerDay = regRateErrPerDay

        if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_RATE"] != nil {
            FileHandle.standardError.write(
                String(format: "[rate] fft=%+.2f s/d  reg=%+.2f s/d  diff=%+.2f  fHz=%.6f  slope_period=%.6f ms\n",
                       fftRateErrPerDay, regRateErrPerDay,
                       fftRateErrPerDay - regRateErrPerDay,
                       winner.fHz, slope * 1000.0).data(using: .utf8)!)
        }

        // Quality from the winner's SNR. Same formula as before — see notes
        // on tightening from snr/5 to snr/10 to keep pure noise (snr ~ 2)
        // below the 30% display gate while real watches saturate above 50.
        let quality = max(0.0, min(1.0, 1.0 - exp(-snr / 10.0)))

        // High-σ gate: route to LowAnalyticalConfidence whenever per-class
        // residual scatter exceeds 8 ms. A watch whose individual tick
        // positions scatter by 8+ ms is too erratic for a useful per-tick
        // display — even the dedicated timegrapher cannot make sense of
        // these recordings (Tim's Timex3Mess: σ ≈ 10, regression slope
        // still hits the right rate but most picks land on noise events
        // near each beat). The user gets a clear "watch is too erratic
        // to analyze" page instead of a misleading rate-with-snowstorm.
        //
        // Threshold tuned from corpus: clean watches σ < 3, sick-but-
        // readable Timexes/Omegas σ < 6, snowstorm Timex3Mess σ ≈ 10.
        // 8 ms gives ~2 ms margin from the worst legitimate sick reading.
        let isLowConfidence = avgClassStd > 8.0

        let beatErrorReported: Double? = beAsymmetryMs
        // Only emit ticks that survived outlier rejection. A pick that
        // failed the per-class quadratic-MAD test is almost certainly a
        // misread (noise event in the gap, wrong sub-event, etc.) — not a
        // real beat that happened at a wildly different time. Don't show
        // it on the timegraph.
        let tickTimings: [TickTiming]
        do {
            let kept = Set(winner.cleanedConfirmed)
            tickTimings = (0..<m).compactMap { i -> TickTiming? in
                guard kept.contains(i) else { return nil }
                let t = slope * Double(i) + intercept + residualsMs[i] / 1000.0
                return TickTiming(beatIndex: i, residualMs: residualsMs[i],
                                  isEvenBeat: i % 2 == 0, timeSeconds: t)
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

    /// Robust slope estimate via two-stage regression: fit on all picks,
    /// drop the worst 50% by residual magnitude, refit on the survivors.
    /// Returns the re-anchored window centers (one per index 0..m-1)
    /// using the robust slope and intercept.
    ///
    /// For a real watch, the basic and robust slopes agree (all picks fit
    /// the line). For a noise-contaminated recording, the robust slope
    /// follows the real ticks (which fit a line) instead of being biased
    /// by the scattered noise picks. Re-anchored windows align real ticks
    /// at consistent sub-box positions in both cases — which is what the
    /// NoiseRejector's position-consistency check requires to work.
    func robustReAnchoredCenters(initialPicks: [Double], windowCount m: Int) -> [Double] {
        // First-pass regression on all picks.
        var sumI = 0.0, sumT = 0.0, sumII = 0.0, sumIT = 0.0
        for i in 0..<m {
            let di = Double(i)
            sumI += di; sumT += initialPicks[i]
            sumII += di * di; sumIT += di * initialPicks[i]
        }
        let denom1 = Double(m) * sumII - sumI * sumI
        guard abs(denom1) > 1e-20 else {
            return initialPicks  // degenerate; just hand back what we got
        }
        let slope1 = (Double(m) * sumIT - sumI * sumT) / denom1
        let intercept1 = (sumT - slope1 * sumI) / Double(m)

        // Compute residuals; sort indices by |residual| ascending; keep
        // the best (lowest-residual) half.
        var indexed: [(idx: Int, absRes: Double)] = []
        indexed.reserveCapacity(m)
        for i in 0..<m {
            let predicted = slope1 * Double(i) + intercept1
            indexed.append((i, abs(initialPicks[i] - predicted)))
        }
        indexed.sort { $0.absRes < $1.absRes }
        let keepCount = max(6, m / 2)
        let kept = indexed.prefix(keepCount).map { $0.idx }

        // Second-pass regression on kept indices.
        var sumI2 = 0.0, sumT2 = 0.0, sumII2 = 0.0, sumIT2 = 0.0
        for i in kept {
            let di = Double(i)
            sumI2 += di; sumT2 += initialPicks[i]
            sumII2 += di * di; sumIT2 += di * initialPicks[i]
        }
        let cm2 = Double(kept.count)
        let denom2 = cm2 * sumII2 - sumI2 * sumI2
        guard abs(denom2) > 1e-20 else {
            // Fall back to first-pass slope if second-pass is degenerate.
            return (0..<m).map { slope1 * Double($0) + intercept1 }
        }
        let slope2 = (cm2 * sumIT2 - sumI2 * sumT2) / denom2
        let intercept2 = (sumT2 - slope2 * sumI2) / cm2

        // Re-anchored window centers using the robust slope.
        return (0..<m).map { slope2 * Double($0) + intercept2 }
    }
}
