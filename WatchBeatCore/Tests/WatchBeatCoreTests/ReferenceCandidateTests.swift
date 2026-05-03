import XCTest
@testable import WatchBeatCore

/// Tests for the composite-score formula on `ReferenceCandidate`. The
/// score is what determines which rate wins when the picker evaluates
/// multiple standard rates for the same recording.
final class ReferenceCandidateTests: XCTestCase {

    /// Build a candidate with controlled inputs. fHz and slope are set
    /// such that slope ≈ 1/fHz (rateConsistency = 1.0) unless overridden.
    private func makeCandidate(
        fHz: Double = 5.0,
        snr: Double = 50,
        confirmedFraction: Double = 1.0,
        avgClassStd: Double = 1.0,
        slopeOverride: Double? = nil
    ) -> ReferenceCandidate {
        let slope = slopeOverride ?? (1.0 / fHz)
        return ReferenceCandidate(
            snappedRate: .bph18000,
            fHz: fHz, phi: 0,
            beatPositions: [],
            slope: slope, intercept: 0,
            residualsMs: [],
            evenMean: 0, oddMean: 0,
            evenStd: 0, oddStd: 0,
            avgClassStd: avgClassStd,
            beAsymmetryMs: 0,
            tickEnergies: [], gapEnergies: [],
            medianTick: 0, medianGap: 0,
            snr: snr,
            confirmedFraction: confirmedFraction,
            cleanedConfirmed: []
        )
    }

    /// A clean watch (high SNR, full confirmation, tight σ, slope matches)
    /// scores near 1.0.
    func test_cleanWatch_scoresNearOne() {
        let c = makeCandidate(snr: 100, confirmedFraction: 1.0, avgClassStd: 0.5)
        // q ≈ 1 - exp(-10) ≈ 1.0
        // sigmaPen = 1 / (1 + 0.25/50) ≈ 0.995
        // confirmedFraction × q × sigmaPen × 1.0 (rateConsistency)
        XCTAssertGreaterThan(c.score, 0.99)
    }

    /// confirmedFraction is the weakest signal and is multiplied directly.
    /// Halving it should halve the score, all else equal.
    func test_confirmedFraction_scalesScoreLinearly() {
        let full = makeCandidate(confirmedFraction: 1.0)
        let half = makeCandidate(confirmedFraction: 0.5)
        XCTAssertEqual(half.score / full.score, 0.5, accuracy: 0.01)
    }

    /// High σ tanks the score via the σ² penalty term. σ=30 ms ≈ 0.053
    /// pen factor — even with all other terms at 1.0, the score is ~5%.
    func test_highSigma_tanksScore() {
        let clean = makeCandidate(avgClassStd: 1.0)
        let messy = makeCandidate(avgClassStd: 30.0)
        XCTAssertLessThan(messy.score, clean.score * 0.1)
    }

    /// rateConsistency is a hard cutoff: if the regression slope deviates
    /// by more than 10% from the candidate's expected period (1/fHz),
    /// score goes to zero. This is what catches harmonic confusion — a
    /// 36000 bph candidate running on a 21600 bph watch sees its picker
    /// lock to the fundamental's spacing, which doesn't match 36000's
    /// expected period.
    func test_slopeMismatch_killsScore() {
        // fHz = 5 (period 0.2), but slope = 0.4 (off by 100%) — way past
        // the 10% cutoff.
        let c = makeCandidate(fHz: 5.0, slopeOverride: 0.4)
        XCTAssertEqual(c.score, 0)
    }

    /// Slope within 10% of expected period passes the rateConsistency
    /// gate and contributes to the final score.
    func test_slopeWithin10Percent_passesGate() {
        // fHz = 5 (expected period 0.200), slope = 0.21 (5% off).
        let c = makeCandidate(fHz: 5.0, slopeOverride: 0.21)
        XCTAssertGreaterThan(c.score, 0)
    }

    /// Pure noise (low SNR) scores low even with everything else perfect.
    /// snr=2 → q ≈ 1 - exp(-0.2) ≈ 0.18.
    func test_lowSNR_lowsScore() {
        let noisy = makeCandidate(snr: 2)
        XCTAssertLessThan(noisy.score, 0.2)
    }
}
