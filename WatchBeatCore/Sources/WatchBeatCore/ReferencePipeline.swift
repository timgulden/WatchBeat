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

        // Front-end filter: spectrogram-based adaptive band selection.
        // Run STFT, score each frequency bin's rhythmicity at standard
        // mechanical beat rates, and bandpass at whatever narrow band
        // shows the strongest periodic signal. Falls back to the broadband
        // 5 kHz highpass when no narrow band meaningfully beats it (1.5×
        // margin gate) — so already-clean broadband recordings stay on
        // the broadband path. Set WATCHBEAT_NO_MULTIBAND=1 to force the
        // broadband-only behavior for diagnostic A/B comparisons.
        var filtered: [Float]
        let multibandEnabled = ProcessInfo.processInfo.environment["WATCHBEAT_NO_MULTIBAND"] == nil
        if multibandEnabled,
           let band = MultibandSelector.selectBestBand(samples: input.samples, sampleRate: sampleRate) {
            filtered = conditioner.bandpassFilter(
                input.samples, sampleRate: sampleRate,
                lowCutoff: band.lowHz, highCutoff: band.highHz
            )
        } else {
            filtered = conditioner.highpassFilter(input.samples, sampleRate: sampleRate, cutoff: Self.highpassCutoffHz)
        }
        let n = filtered.count

        // Impulse suppression — phase-aware:
        //   Each sample above 100× median |signal| is a candidate for
        //   suppression. Candidates that are within ~0.5 ms of each
        //   other are grouped into clusters; clusters spanning ≥ 3 ms
        //   are "wide" (flick-like by shape).
        //
        //   Before suppressing, we check whether the wide clusters lie
        //   on a rhythm matching a standard mechanical beat rate. A
        //   loud watch (close mic, high amplitude) can produce wide
        //   clusters at every tock or every tick — those are real beats,
        //   not flicks, and suppressing them makes the picker lock onto
        //   adjacent sub-events instead of the dominant peak. Phase-
        //   awareness preserves loud rhythmic events while still
        //   excising scattered taps/bumps.
        //
        //   Per-cluster classification (not all-or-nothing): each wide
        //   cluster is judged independently. A cluster is "in rhythm"
        //   if its time gaps to both neighbors are integer multiples of
        //   the best-fit standard-rate base period within ±5 ms. Edge
        //   clusters check their single available gap. In-rhythm wide
        //   clusters are left alone (no per-sample clip, no excise);
        //   off-rhythm wide clusters AND all narrow clusters get per-
        //   sample clipped, and off-rhythm wide clusters are also
        //   excised when their count is < 10 (the flick-vs-tick gate
        //   the old code used unconditionally).
        let absVals = filtered.map { abs($0) }.sorted()
        let medianAbs = absVals[absVals.count / 2]
        if medianAbs > 0 {
            let clipLevel = 100 * medianAbs

            // Find clip-worthy positions WITHOUT modifying the signal —
            // we need to inspect the cluster structure before deciding
            // which positions to actually clip.
            var clipPositions: [Int] = []
            for i in 0..<n {
                if filtered[i] > clipLevel || filtered[i] < -clipLevel {
                    clipPositions.append(i)
                }
            }

            // Form clusters: groups of clip positions within ~0.5 ms of
            // each other (same physical event).
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

            let wideClusters = allClusters.filter { $0.end - $0.start >= minImpulseSpan }

            // Phase-aware classification of wide clusters.
            let preservedStarts: Set<Int> = Self.identifyInRhythmWideClusters(
                wideClusters, sampleRate: sampleRate
            )

            // Per-sample clip everything EXCEPT samples inside preserved
            // (in-rhythm wide) clusters. Walk clip positions and active
            // cluster in tandem — both lists are sorted, so this is O(n).
            var clusterIdx = 0
            for pos in clipPositions {
                while clusterIdx < allClusters.count && allClusters[clusterIdx].end < pos {
                    clusterIdx += 1
                }
                if clusterIdx < allClusters.count,
                   allClusters[clusterIdx].start <= pos,
                   pos <= allClusters[clusterIdx].end,
                   preservedStarts.contains(allClusters[clusterIdx].start) {
                    continue
                }
                if filtered[pos] > clipLevel {
                    filtered[pos] = clipLevel
                } else if filtered[pos] < -clipLevel {
                    filtered[pos] = -clipLevel
                }
            }

            // Excise only off-rhythm wide clusters. Preserves the count-
            // adaptive gate (< 10 = flicks → excise; ≥ 10 = wide-tick
            // watch family → not excised even if off-rhythm) on the
            // OFF-RHYTHM subset — so a sick watch whose ticks all fall
            // off rhythm still doesn't get its ticks zeroed if there
            // are many of them.
            let offRhythmWide = wideClusters.filter { !preservedStarts.contains($0.start) }
            var excisePositions: [Int] = []
            if offRhythmWide.count < 10 {
                for (s, e) in offRhythmWide {
                    excisePositions.append((s + e) / 2)
                }
            }

            if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_CLIP"] != nil {
                FileHandle.standardError.write("[clip] total_clusters=\(allClusters.count) wide(>=3ms)=\(wideClusters.count) preserved=\(preservedStarts.count) offRhythm=\(offRhythmWide.count) excised=\(excisePositions.count)\n".data(using: .utf8)!)
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

            // Class-consensus rescue: after pure-argmax picking, some beats
            // can lock onto a secondary sub-event instead of the dominant
            // peak — most often a tock whose dominant peak momentarily
            // dips below an adjacent post-tock echo (or vice versa for
            // ticks). The picker has no per-beat way to choose between
            // competing peaks; class consensus does. Algorithm:
            //   1. Fit joint regression to current beatPositions.
            //   2. Compute per-class (even / odd) median residual — the
            //      typical position of each parity relative to the
            //      regression line.
            //   3. For each beat, expected_t = regression(beat_idx) +
            //      class_median. If pick is > 2 ms from expected AND a
            //      competing peak exists within ±2 ms of expected with
            //      amplitude ≥ 50% of the current pick's amplitude,
            //      switch to that peak. The amplitude ratio prevents
            //      pulling picks to noise floors when there's no credible
            //      alternative; the 2 ms tolerance leaves room for
            //      legitimate per-beat variation while catching obvious
            //      sub-event flips.
            if m >= 10 {
                var sumI3 = 0.0, sumT3 = 0.0, sumII3 = 0.0, sumIT3 = 0.0
                for i in 0..<m {
                    let di = Double(i)
                    sumI3 += di; sumT3 += beatPositions[i]
                    sumII3 += di * di; sumIT3 += di * beatPositions[i]
                }
                let denom3 = Double(m) * sumII3 - sumI3 * sumI3
                if abs(denom3) > 1e-20 {
                    let slope3 = (Double(m) * sumIT3 - sumI3 * sumT3) / denom3
                    let intercept3 = (sumT3 - slope3 * sumI3) / Double(m)
                    var evenRes: [Double] = []
                    var oddRes: [Double] = []
                    for i in 0..<m {
                        let pred = slope3 * Double(i) + intercept3
                        let r = beatPositions[i] - pred
                        if i % 2 == 0 { evenRes.append(r) } else { oddRes.append(r) }
                    }
                    evenRes.sort(); oddRes.sort()
                    let evenMedian = evenRes.isEmpty ? 0 : evenRes[evenRes.count / 2]
                    let oddMedian = oddRes.isEmpty ? 0 : oddRes[oddRes.count / 2]
                    let consensusTolSec = 0.002
                    let rescueHalf = max(1, Int(0.002 * sampleRate))
                    let amplitudeRatio: Float = 0.5
                    var rescueCount = 0
                    for w in 0..<m {
                        let pred = slope3 * Double(w) + intercept3
                        let classMedian = w % 2 == 0 ? evenMedian : oddMedian
                        let expected = pred + classMedian
                        if abs(beatPositions[w] - expected) <= consensusTolSec { continue }
                        let expSample = Int(round(expected * sampleRate))
                        let lo = max(0, expSample - rescueHalf)
                        let hi = min(n - 1, expSample + rescueHalf)
                        guard lo < hi else { continue }
                        var bestIdx = lo
                        var bestVal: Float = -.infinity
                        for i in lo...hi {
                            if smoothed[i] > bestVal { bestVal = smoothed[i]; bestIdx = i }
                        }
                        let curIdx = Int(round(beatPositions[w] * sampleRate))
                        let curVal: Float = (curIdx >= 0 && curIdx < n) ? smoothed[curIdx] : 0
                        if curVal > 0 && bestVal >= amplitudeRatio * curVal {
                            beatPositions[w] = Double(bestIdx) / sampleRate
                            rescueCount += 1
                        }
                    }
                    if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_RESCUE"] != nil {
                        FileHandle.standardError.write("[rescue] rate=\(snappedRate.rawValue) evenMed=\(String(format: "%+.2f", evenMedian * 1000))ms oddMed=\(String(format: "%+.2f", oddMedian * 1000))ms rescued=\(rescueCount)/\(m)\n".data(using: .utf8)!)
                    }

                    // Sub-event-flipping fix: per-class lock-in, gated on
                    // asymmetric MAD. The signature of sub-event flipping
                    // on well-regulated watches is one class with very
                    // tight picks (showing the picker's intrinsic sub-ms
                    // precision) and the other class visibly looser —
                    // typically because two competing acoustic sub-events
                    // are close to equal amplitude on one parity, so the
                    // picker oscillates between them beat-to-beat.
                    //
                    // When MAD is asymmetric, the tight class proves the
                    // class median is trustworthy, and the loose class's
                    // picks can safely be pulled toward (regression +
                    // class_median) ±0.5 ms. When both MADs are moderate
                    // (weak signal, no consensus) or both tight (picker
                    // already happy), the gate stays silent — preserving
                    // the rest of the pipeline's behavior.
                    //
                    // Set WATCHBEAT_NO_LOCKIN=1 to disable.
                    if ProcessInfo.processInfo.environment["WATCHBEAT_NO_LOCKIN"] == nil {
                        var ev: [Double] = []
                        var od: [Double] = []
                        for i in 0..<m {
                            let pred = slope3 * Double(i) + intercept3
                            let r = beatPositions[i] - pred
                            if i % 2 == 0 { ev.append(r) } else { od.append(r) }
                        }
                        func mad(_ a: [Double]) -> Double {
                            guard !a.isEmpty else { return 0 }
                            let sorted = a.sorted()
                            let med = sorted[sorted.count / 2]
                            let absDevs = sorted.map { abs($0 - med) }.sorted()
                            return absDevs[absDevs.count / 2]
                        }
                        let evMAD = mad(ev)
                        let odMAD = mad(od)
                        let minMADSec = min(evMAD, odMAD)
                        let maxMADSec = max(evMAD, odMAD)
                        // Fire when one class has MAD < 0.2 ms (confirmed
                        // sub-ms picker precision) AND the other is at
                        // least 2× looser (sub-event flipping signature).
                        let madTight = 0.0002
                        let asymmetricFlip = minMADSec < madTight && maxMADSec >= 2.0 * minMADSec
                        if asymmetricFlip {
                            // Two safeguards prevent overoptimistic picks:
                            //   (a) Loose-class-only: re-pick only the
                            //       class showing the flip signature. The
                            //       tight class is already at picker
                            //       precision — touching it can only do
                            //       harm.
                            //   (b) Amplitude floor: only replace a pick
                            //       if the new position's smoothed
                            //       amplitude is at least 50% of the
                            //       current pick's amplitude. Prevents
                            //       grabbing a tiny noise peak near the
                            //       consensus window while ignoring a
                            //       clearly stronger signal just outside.
                            let looseIsEven = (evMAD > odMAD)
                            let looseMedian = looseIsEven ? evenMedian : oddMedian
                            let lockHalf = max(1, Int(0.0005 * sampleRate))
                            let amplitudeRatio: Float = 0.5
                            var lockCount = 0
                            var rejectAmp = 0
                            for w in 0..<m {
                                let isEvenBeat = (w % 2 == 0)
                                if isEvenBeat != looseIsEven { continue }  // tight class untouched
                                let pred = slope3 * Double(w) + intercept3
                                let expected = pred + looseMedian
                                let expSample = Int(round(expected * sampleRate))
                                let lo = max(0, expSample - lockHalf)
                                let hi = min(n - 1, expSample + lockHalf)
                                guard lo < hi else { continue }
                                var bestIdx = lo
                                var bestVal: Float = -.infinity
                                for i in lo...hi {
                                    if smoothed[i] > bestVal { bestVal = smoothed[i]; bestIdx = i }
                                }
                                let curIdx = Int(round(beatPositions[w] * sampleRate))
                                let curVal: Float = (curIdx >= 0 && curIdx < n) ? smoothed[curIdx] : 0
                                guard curVal > 0, bestVal >= amplitudeRatio * curVal else {
                                    rejectAmp += 1
                                    continue
                                }
                                let newT = Double(bestIdx) / sampleRate
                                if abs(newT - beatPositions[w]) > 1e-9 {
                                    beatPositions[w] = newT
                                    lockCount += 1
                                }
                            }
                            if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_RESCUE"] != nil {
                                FileHandle.standardError.write("[class-lockin] evMAD=\(String(format: "%.2f", evMAD * 1000))ms odMAD=\(String(format: "%.2f", odMAD * 1000))ms looseClass=\(looseIsEven ? "EVEN" : "ODD") re-picked=\(lockCount) ampReject=\(rejectAmp)\n".data(using: .utf8)!)
                            }
                        } else if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_RESCUE"] != nil {
                            FileHandle.standardError.write("[class-lockin] no asymmetry: evMAD=\(String(format: "%.2f", evMAD * 1000))ms odMAD=\(String(format: "%.2f", odMAD * 1000))ms (skipped)\n".data(using: .utf8)!)
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
            var cleanedConfirmed = (rejector.clean(evenIdxs) + rejector.clean(oddIdxs)).sorted()
            guard cleanedConfirmed.count >= 6 else { return nil }

            // Matched-filter refinement: build an averaged tick template
            // from the cleaned picks (each tick's 20 ms envelope window,
            // aligned to its current position), then cross-correlate each
            // tick's envelope against the template to refine its position
            // to sub-sample precision. The template captures the watch's
            // characteristic tick shape — beat-to-beat picker noise
            // cancels out in the average; the consistent shape survives.
            // Each tick then snaps to wherever the template best aligns,
            // not wherever the local smoothed-argmax happened to land.
            //
            // Sister-trims its own outliers via 3σ class-wise filtering
            // on the refined positions. The result: tighter per-tick
            // residuals than any single-beat pick can produce on watches
            // with a consistent tick shape.
            //
            // Set WATCHBEAT_NO_MATCHED_FILTER=1 to disable.
            if ProcessInfo.processInfo.environment["WATCHBEAT_NO_MATCHED_FILTER"] == nil {
                let tickPositions = cleanedConfirmed.map { beatPositions[$0] }
                let refined = MatchedFilterRefinement.refinePositions(
                    squared: squared,
                    sampleRate: sampleRate,
                    tickPositions: tickPositions,
                    beatIndices: cleanedConfirmed
                )
                // Apply refined positions to beatPositions; collect survivor indices.
                var survivors: [Int] = []
                survivors.reserveCapacity(cleanedConfirmed.count)
                for (k, idx) in cleanedConfirmed.enumerated() {
                    if let r = refined[k] {
                        beatPositions[idx] = r
                        survivors.append(idx)
                    }
                }
                // Only adopt the refined set if it leaves a usable number
                // of beats. If matched filter trimmed too aggressively
                // (rare), fall back to the pre-refinement cleaned set.
                if survivors.count >= 6 {
                    cleanedConfirmed = survivors
                }
                if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_MATCHED_FILTER"] != nil {
                    FileHandle.standardError.write("[matched-filter] rate=\(snappedRate.rawValue) input=\(tickPositions.count) survivors=\(survivors.count) kept=\(cleanedConfirmed.count)\n".data(using: .utf8)!)
                }
            }

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
        // function used to compute directly. Some are var so the cross-class
        // rescue below can rewrite them in place.
        let snappedRate = winner.snappedRate
        var beatPositions = winner.beatPositions
        let m = beatPositions.count
        var slope = winner.slope
        var intercept = winner.intercept
        var residualsMs = winner.residualsMs
        var avgClassStd = winner.avgClassStd
        var beAsymmetryMs = winner.beAsymmetryMs
        var evenStd = winner.evenStd
        var oddStd = winner.oddStd
        let snr = winner.snr
        let confirmedFraction = winner.confirmedFraction

        // Cross-class sub-event correspondence rescue. Runs ONLY on the
        // winning candidate so wrong-rate candidates can't be artificially
        // improved by it (which would corrupt candidate scoring).
        //
        // Detects the "mirrored sub-event" failure pattern: each class is
        // internally tight, but their average residuals are large with
        // opposite signs — meaning the picker locked onto different
        // acoustic sub-events in tick vs tock windows. Caught on the
        // 2026-06-26 NH35 recording (even μ=+4.20ms, odd μ=-3.81ms,
        // BE 8 ms reported; same watch consistently reads BE 1 ms ~50% of
        // recordings).
        //
        // Algorithm:
        //   1. Detect mirror pattern (|even+odd| < 2 ms AND |even-odd| > 4 ms).
        //   2. Build per-class average envelope templates from picks.
        //   3. Find prominent peaks (≥ 50% of class dominant) in each.
        //   4. Score all (tick peak, tock peak) combinations on:
        //      - smaller |Δoffset| (smaller BE — only better-than-current accepted)
        //      - bonus for same position-in-sequence (corresponding mechanical
        //        events appear at the same rank in each class's peak sequence)
        //      - combined amplitude (avoids switching to noise floor)
        //   5. If a meaningfully better configuration exists, re-pick all
        //      beats with argmax in narrow window around the new offset.
        //
        // Set WATCHBEAT_NO_CROSS_CLASS=1 to disable for diagnostic A/B.
        if ProcessInfo.processInfo.environment["WATCHBEAT_NO_CROSS_CLASS"] == nil {
            let kept = winner.cleanedConfirmed
            var preEvenSum = 0.0, preOddSum = 0.0
            var preEvenN = 0, preOddN = 0
            for idx in kept {
                let res = beatPositions[idx] - (slope * Double(idx) + intercept)
                if idx % 2 == 0 { preEvenSum += res; preEvenN += 1 }
                else { preOddSum += res; preOddN += 1 }
            }
            let preEvenMs = preEvenN > 0 ? (preEvenSum / Double(preEvenN)) * 1000.0 : 0
            let preOddMs = preOddN > 0 ? (preOddSum / Double(preOddN)) * 1000.0 : 0
            let symMagnitude = abs(preEvenMs + preOddMs)
            let totalSpread = abs(preEvenMs - preOddMs)
            let mirroredPattern = symMagnitude < 2.0 && totalSpread > 4.0

            if mirroredPattern {
                // Build per-class average envelope template (peak-normalized).
                let templateHalfMs: Double = 10.0
                let templatePoints = 401
                let msPerPoint = (2.0 * templateHalfMs) / Double(templatePoints - 1)
                func buildTemplate(forEven: Bool) -> [Float] {
                    var template = [Double](repeating: 0, count: templatePoints)
                    var contribs = 0
                    for idx in kept where (idx % 2 == 0) == forEven {
                        let predicted = slope * Double(idx) + intercept
                        let centerSamp = Int(round(predicted * sampleRate))
                        var localT = [Double](repeating: 0, count: templatePoints)
                        var localMax: Float = 0
                        for k in 0..<templatePoints {
                            let msOff = -templateHalfMs + Double(k) * msPerPoint
                            let absIdx = centerSamp + Int(round(msOff / 1000.0 * sampleRate))
                            if absIdx >= 0 && absIdx < n {
                                let v = smoothed[absIdx]
                                localT[k] = Double(v)
                                if v > localMax { localMax = v }
                            }
                        }
                        if localMax > 0 {
                            let inv = 1.0 / Double(localMax)
                            for k in 0..<templatePoints { template[k] += localT[k] * inv }
                            contribs += 1
                        }
                    }
                    if contribs > 0 {
                        for k in 0..<templatePoints { template[k] /= Double(contribs) }
                    }
                    return template.map { Float($0) }
                }
                let evenTemplate = buildTemplate(forEven: true)
                let oddTemplate = buildTemplate(forEven: false)

                // Peak finder: local maxima ≥ 50% of class dominant, min 1 ms separation.
                func findPeaks(_ t: [Float]) -> [(offsetMs: Double, amplitude: Double)] {
                    let maxAmp = t.max() ?? 0
                    guard maxAmp > 0 else { return [] }
                    let threshold = 0.5 * maxAmp
                    var peaks: [(offsetMs: Double, amplitude: Double)] = []
                    for i in 1..<(t.count - 1) {
                        if t[i] >= threshold && t[i] > t[i - 1] && t[i] >= t[i + 1] {
                            let offsetMs = -templateHalfMs + Double(i) * msPerPoint
                            let amp = Double(t[i]) / Double(maxAmp)
                            if let last = peaks.last, offsetMs - last.offsetMs < 1.0 {
                                if amp > last.amplitude {
                                    peaks[peaks.count - 1] = (offsetMs, amp)
                                }
                            } else {
                                peaks.append((offsetMs, amp))
                            }
                        }
                    }
                    return peaks
                }
                let evenPeaks = findPeaks(evenTemplate)
                let oddPeaks = findPeaks(oddTemplate)

                if !evenPeaks.isEmpty && !oddPeaks.isEmpty {
                    // HARD REQUIREMENT: posMatch must be true. The position-
                    // in-sequence match is the principled test that the two
                    // chosen peaks correspond to the same physical mechanical
                    // event in tick and tock — preventing wrong-event
                    // substitution that produces misleadingly-small BE on
                    // watches with genuinely large beat error (e.g.,
                    // Timex1_Strays has real BE ≈ 5 ms; without this gate,
                    // cross-class would suppress it to 1 ms).
                    let currentBE = totalSpread
                    var bestScore: Double = -.infinity
                    var bestPair: (Int, Int)? = nil
                    for (ei, evP) in evenPeaks.enumerated() {
                        for (oi, oP) in oddPeaks.enumerated() {
                            guard ei == oi else { continue }   // hard posMatch requirement
                            let candidateBE = abs(evP.offsetMs - oP.offsetMs)
                            if candidateBE >= currentBE - 1.0 { continue }
                            let score = evP.amplitude + oP.amplitude
                            if score > bestScore {
                                bestScore = score
                                bestPair = (ei, oi)
                            }
                        }
                    }

                    if let (ei, oi) = bestPair {
                        let newEvenSec = evenPeaks[ei].offsetMs / 1000.0
                        let newOddSec = oddPeaks[oi].offsetMs / 1000.0
                        let rescueHalfSamp = max(1, Int(0.0015 * sampleRate))
                        var moveCount = 0
                        for idx in kept {
                            let predicted = slope * Double(idx) + intercept
                            let classOffset = (idx % 2 == 0) ? newEvenSec : newOddSec
                            let targetSamp = Int(round((predicted + classOffset) * sampleRate))
                            let lo = max(0, targetSamp - rescueHalfSamp)
                            let hi = min(n - 1, targetSamp + rescueHalfSamp)
                            guard lo < hi else { continue }
                            var bIdx = lo
                            var bVal: Float = -.infinity
                            for j in lo...hi {
                                if smoothed[j] > bVal { bVal = smoothed[j]; bIdx = j }
                            }
                            let newT = Double(bIdx) / sampleRate
                            if abs(newT - beatPositions[idx]) > 1e-9 {
                                beatPositions[idx] = newT
                                moveCount += 1
                            }
                        }

                        // Refit regression + residuals + per-class stats + BE.
                        var sI = 0.0, sT = 0.0, sII = 0.0, sIT = 0.0
                        for idx in kept {
                            let di = Double(idx)
                            sI += di; sT += beatPositions[idx]
                            sII += di * di; sIT += di * beatPositions[idx]
                        }
                        let c = Double(kept.count)
                        let denom = c * sII - sI * sI
                        if abs(denom) > 1e-20 {
                            slope = (c * sIT - sI * sT) / denom
                            intercept = (sT - slope * sI) / c
                        }
                        residualsMs = [Double](repeating: 0, count: m)
                        for i in 0..<m {
                            residualsMs[i] = (beatPositions[i] - (slope * Double(i) + intercept)) * 1000.0
                        }
                        var eS = 0.0, oS = 0.0, eSq = 0.0, oSq = 0.0, eN = 0, oN = 0
                        for idx in kept {
                            let r = residualsMs[idx]
                            if idx % 2 == 0 { eS += r; eSq += r * r; eN += 1 }
                            else { oS += r; oSq += r * r; oN += 1 }
                        }
                        let eMean = eN > 0 ? eS / Double(eN) : 0
                        let oMean = oN > 0 ? oS / Double(oN) : 0
                        evenStd = eN > 0 ? sqrt(max(0, eSq / Double(eN) - eMean * eMean)) : 0
                        oddStd = oN > 0 ? sqrt(max(0, oSq / Double(oN) - oMean * oMean)) : 0
                        avgClassStd = (evenStd + oddStd) / 2.0
                        var resByBeat: [Int: Double] = [:]
                        for idx in kept { resByBeat[idx] = residualsMs[idx] / 1000.0 }
                        beAsymmetryMs = (BeatError.meanPairedAbsDifference(residualsByBeat: resByBeat) ?? 0) * 1000.0

                        if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_CROSS_CLASS"] != nil {
                            FileHandle.standardError.write("[cross-class] WINNER rate=\(snappedRate.rawValue) wasBE=\(String(format: "%.2f", currentBE))ms newBE=\(String(format: "%.2f", abs(newEvenSec - newOddSec) * 1000))ms posMatch=\(ei == oi) moved=\(moveCount)/\(kept.count)\n".data(using: .utf8)!)
                        }
                    } else if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_CROSS_CLASS"] != nil {
                        FileHandle.standardError.write("[cross-class] mirror but no better config: even=\(String(format: "%+.2f", preEvenMs))ms odd=\(String(format: "%+.2f", preOddMs))ms\n".data(using: .utf8)!)
                    }
                }
            } else if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_CROSS_CLASS"] != nil {
                FileHandle.standardError.write("[cross-class] no mirror: even=\(String(format: "%+.2f", preEvenMs))ms odd=\(String(format: "%+.2f", preOddMs))ms (skipped)\n".data(using: .utf8)!)
            }
        }

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

        // Low-confidence routing — two independent gates:
        //
        // (a) High-σ gate: route to LowAnalyticalConfidence whenever
        //     the AVERAGE per-class residual scatter exceeds the
        //     threshold (currently 10 ms). Catches uniformly-erratic
        //     recordings (Timex3Mess: σ ≈ 10) where the regression
        //     slope still hits the right rate but most picks land on
        //     noise events near each beat.
        //
        // (b) Asymmetric per-class σ gate: when one class shows clean
        //     tight picks but the other is hopelessly scattered, the
        //     reported BE (computed from cross-class pairing) is
        //     unreliable even though average σ may look fine. Caught
        //     on the 2026-05-26 Timex "terrible_ticks_good_rocks"
        //     recording (even σ=2.97, odd σ=0.35; ratio 8.5×). The
        //     rate is plausible but the displayed BE of 8 ms is a
        //     fiction of the scattered class. Better to route to
        //     try-again than to display the misleading number.
        //
        // Fires when: max(class σ) / min(class σ) ≥ 5  AND
        //             max(class σ) ≥ 1 ms (rules out cases where both
        //             classes are sub-ms and the ratio is just noise).
        // evenStd / oddStd were unpacked from the winner above and may have
        // been updated by the cross-class rescue. Use those values here.
        let maxClassStd = max(evenStd, oddStd)
        let minClassStd = max(min(evenStd, oddStd), 1e-9)  // avoid div by zero
        let asymmetricClassFailure = maxClassStd / minClassStd >= 5.0 && maxClassStd >= 1.0
        let isLowConfidence = avgClassStd > Self.lowConfidenceMaxClassSigmaMs
                            || asymmetricClassFailure

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

    /// Quartz-watch detection on the RAW (no-highpass) signal.
    ///
    /// Quartz watches click once per second, producing a sharp pulse
    /// train at exactly 1 Hz. The FFT of a 1 Hz pulse train shows energy
    /// at INTEGER Hz harmonics: 1, 2, 3, 4, 5 Hz, etc. The exact
    /// distribution across harmonics depends on the click waveform — a
    /// simple click peaks at 1 Hz; a chrono-running quartz often peaks
    /// at higher harmonics (4 Hz observed on real recordings). The
    /// invariant is that the integer-Hz bins are systematically larger
    /// than their half-integer neighbors (1.5, 2.5, 3.5, 4.5 Hz).
    ///
    /// Detection: rectify raw signal → decimate to 1 kHz → Hann + FFT →
    /// compare sum of integer-Hz bins (1, 2, 3, 4 Hz) to sum of half-
    /// integer-Hz bins (1.5, 2.5, 3.5, 4.5 Hz). If integer/half > 1.3,
    /// the recording has quartz harmonic structure.
    ///
    /// Intended call site: ONLY when the main pipeline would otherwise
    /// route to Weak Signal. Mechanical recordings with broadband noise
    /// (e.g., flicks) can also produce integer-dominant patterns, but
    /// those reach the result page successfully via the normal path
    /// (low σ, high confirmedFraction) and never hit this fallback. The
    /// 1.3 threshold is corpus-tuned for the post-Weak-Signal context.
    public static func detectQuartz(rawSamples: [Float], sampleRate: Double) -> Bool {
        let n = rawSamples.count
        guard n > Int(sampleRate * 5) else { return false }  // need ≥ 5 s

        // Bandpass 6-7 kHz before envelope detection. Tim's spectrum-
        // analyzer measurements showed both quartz watches have their
        // 1 Hz click energy concentrated (or at least present) in the
        // 6-7 kHz band. Isolating that band dramatically improves the
        // click's signal-to-noise vs ambient sounds (HVAC, voices, mid-
        // band noise) which sit elsewhere in the spectrum.
        let conditioner = SignalConditioner()
        let filtered = conditioner.bandpassFilter(
            rawSamples, sampleRate: sampleRate,
            lowCutoff: 6000, highCutoff: min(7000, sampleRate / 2 - 100)
        )

        // Rectify (envelope detection).
        var rectified = [Float](repeating: 0, count: n)
        vDSP_vabs(filtered, 1, &rectified, 1, vDSP_Length(n))

        // Decimate to ~1 kHz with simple averaging.
        let decimFactor = max(1, Int(sampleRate / 1000.0))
        let envRate = sampleRate / Double(decimFactor)
        let envN = n / decimFactor
        var env = [Float](repeating: 0, count: envN)
        for i in 0..<envN {
            var ws: Float = 0
            vDSP_sve(rectified.withUnsafeBufferPointer { $0.baseAddress! + i * decimFactor }, 1,
                     &ws, vDSP_Length(decimFactor))
            env[i] = ws / Float(decimFactor)
        }

        // Remove DC.
        var meanEnv: Float = 0
        vDSP_meanv(env, 1, &meanEnv, vDSP_Length(envN))
        var negMean = -meanEnv
        vDSP_vsadd(env, 1, &negMean, &env, 1, vDSP_Length(envN))

        // Hann window in place.
        var hann = [Float](repeating: 0, count: envN)
        vDSP_hann_window(&hann, vDSP_Length(envN), Int32(vDSP_HANN_NORM))
        vDSP_vmul(env, 1, hann, 1, &env, 1, vDSP_Length(envN))

        // Pad to next power of 2.
        let log2N = max(1, Int(ceil(log2(Double(envN)))))
        let fftLength = 1 << log2N
        var realIn = [Float](repeating: 0, count: fftLength)
        var imagIn = [Float](repeating: 0, count: fftLength)
        for i in 0..<envN { realIn[i] = env[i] }

        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2N), Int32(kFFTRadix2)) else { return false }
        defer { vDSP_destroy_fftsetup(setup) }
        realIn.withUnsafeMutableBufferPointer { rb in
            imagIn.withUnsafeMutableBufferPointer { ib in
                var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, vDSP_Length(log2N), Int32(FFT_FORWARD))
            }
        }

        let halfN = fftLength / 2
        let freqRes = envRate / Double(fftLength)

        // Helper: magnitude at the FFT bin nearest a given Hz value.
        func mag(at hz: Double) -> Float {
            let bin = Int(round(hz / freqRes))
            guard bin > 0 && bin < halfN - 1 else { return 0 }
            return sqrt(realIn[bin] * realIn[bin] + imagIn[bin] * imagIn[bin])
        }

        // Sum integer-Hz peaks (1, 2, 3, 4 Hz) and half-integer-Hz peaks
        // (1.5, 2.5, 3.5, 4.5 Hz). Quartz produces a 1 Hz pulse train
        // whose harmonic comb stands above the half-integer noise floor.
        let integerSum = mag(at: 1.0) + mag(at: 2.0) + mag(at: 3.0) + mag(at: 4.0)
        let halfSum = mag(at: 1.5) + mag(at: 2.5) + mag(at: 3.5) + mag(at: 4.5)

        if ProcessInfo.processInfo.environment["WATCHBEAT_DEBUG_QUARTZ"] != nil {
            let ratio = halfSum > 0 ? integerSum / halfSum : -1
            FileHandle.standardError.write(
                "[quartz] int(1-4)=\(integerSum) half(1.5-4.5)=\(halfSum) ratio=\(ratio)\n".data(using: .utf8)!)
            var msg = "[quartz-spectrum]"
            for fhz in stride(from: 0.5, through: 12.0, by: 0.5) {
                msg += String(format: " %.1fHz=%.4f", fhz, mag(at: fhz))
            }
            msg += "\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
        }

        // Threshold lives in MeasurementPipeline.quartzDetectorIntegerToHalfMinRatio.
        return halfSum > 0 && integerSum > Float(Self.quartzDetectorIntegerToHalfMinRatio) * halfSum
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

    /// Identify wide impulse clusters that fit a standard mechanical
    /// beat-rate rhythm — loud watch ticks that should NOT be suppressed.
    ///
    /// Algorithm:
    ///   - For each standard oscillation Hz, the tick-to-tock base
    ///     period is 1/(2·oscHz). Real ticks/tocks have inter-event
    ///     gaps that are integer multiples of this period (k=1 when
    ///     both tick and tock are loud enough to clip, k=2 when only
    ///     one parity clips, larger k when some intermediate ticks
    ///     are quieter and don't trip clipping).
    ///   - For each candidate base period, count clusters whose gaps
    ///     to both neighbors are integer multiples (k ∈ [1, 10])
    ///     within ±5 ms. Edge clusters check only their single available
    ///     gap.
    ///   - Pick the base period with the highest count. If at least
    ///     50% of wide clusters fit that period, return those clusters
    ///     (identified by their `start` sample) as the "preserved" set.
    ///   - With < 3 wide clusters, no rhythm can be established —
    ///     return empty (fall back to old all-or-nothing excise).
    ///
    /// Tolerance is fixed at 5 ms because rate drift over 15 s is
    /// sub-millisecond, beat error rarely exceeds 3 ms, and 5 ms is
    /// well below the smallest base period (50 ms for 36000 bph).
    static func identifyInRhythmWideClusters(
        _ wideClusters: [(start: Int, end: Int)],
        sampleRate: Double
    ) -> Set<Int> {
        guard wideClusters.count >= 3 else { return [] }

        let centers = wideClusters.map { Double(($0.start + $0.end) / 2) / sampleRate }
        var gaps: [Double] = []
        for i in 1..<centers.count {
            gaps.append(centers[i] - centers[i - 1])
        }

        // Standard mechanical oscillation Hz (matches the rates in the
        // app — quartz excluded since it doesn't have a tick/tock split).
        let standardOscHz: [Double] = [2.5, 2.75, 3.0, 3.5, 4.0, 5.0]
        let tolerance: Double = 0.005
        let kMax = 10

        func fits(_ gap: Double, basePeriod: Double) -> Bool {
            let k = (gap / basePeriod).rounded()
            return k >= 1 && k <= Double(kMax) && abs(gap - k * basePeriod) <= tolerance
        }

        func countFitting(basePeriod: Double) -> Int {
            var count = 0
            for i in 0..<wideClusters.count {
                let prevGap: Double? = (i > 0) ? gaps[i - 1] : nil
                let nextGap: Double? = (i < gaps.count) ? gaps[i] : nil
                let prevFits = prevGap.map { fits($0, basePeriod: basePeriod) } ?? false
                let nextFits = nextGap.map { fits($0, basePeriod: basePeriod) } ?? false
                let inRhythm: Bool
                if prevGap == nil { inRhythm = nextFits }
                else if nextGap == nil { inRhythm = prevFits }
                else { inRhythm = prevFits && nextFits }
                if inRhythm { count += 1 }
            }
            return count
        }

        var bestOsc: Double? = nil
        var bestCount = 0
        for oscHz in standardOscHz {
            let c = countFitting(basePeriod: 1.0 / (2.0 * oscHz))
            if c > bestCount {
                bestCount = c
                bestOsc = oscHz
            }
        }

        // Require at least 50% of wide clusters fit before declaring
        // "rhythmic." Below that, the cluster set is dominated by
        // arrhythmic events (flicks/bumps) and the few coincidental
        // matches don't justify preserving anything.
        guard let oscHz = bestOsc, bestCount * 2 >= wideClusters.count else {
            return []
        }

        let basePeriod = 1.0 / (2.0 * oscHz)
        var preserved: Set<Int> = []
        for i in 0..<wideClusters.count {
            let prevGap: Double? = (i > 0) ? gaps[i - 1] : nil
            let nextGap: Double? = (i < gaps.count) ? gaps[i] : nil
            let prevFits = prevGap.map { fits($0, basePeriod: basePeriod) } ?? false
            let nextFits = nextGap.map { fits($0, basePeriod: basePeriod) } ?? false
            let inRhythm: Bool
            if prevGap == nil { inRhythm = nextFits }
            else if nextGap == nil { inRhythm = prevFits }
            else { inRhythm = prevFits && nextFits }
            if inRhythm {
                preserved.insert(wideClusters[i].start)
            }
        }
        return preserved
    }
}
