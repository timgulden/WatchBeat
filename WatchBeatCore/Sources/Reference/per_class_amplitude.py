#!/usr/bin/env python3
"""
Per-class amplitude extraction from Reference's evenShape/oddShape JSON.

Theory: each class's average envelope is peak-aligned and peak-normalized,
so the dominant sub-event is at t=0. Find the other strong sub-events
(local maxima) and use their positions to compute pulse width for the
amplitude formula. No tick/tock confusion since each class is analyzed
independently. Average the two for the final reading.

For each class shape:
  1. Find the dominant peak (already at index = shapeHalfMs samples → t=0).
  2. Find local maxima in the rest of the shape, ranked by amplitude.
  3. The two strongest non-dominant peaks are sub-events 2 and 3.
  4. Pulse width candidate: smallest sub-event spacing (tightest cluster).
  5. Apply A = L / (2·sin(π·pulse/T_beat)).
"""
import json
import math
import sys
from pathlib import Path


def find_peaks(arr, min_prominence_frac=0.01):
    """Return list of (index, amplitude) for local maxima with prominence
    above min_prominence_frac of the global max."""
    n = len(arr)
    peaks = []
    global_max = max(arr)
    threshold = global_max * min_prominence_frac
    for i in range(2, n - 2):
        if arr[i] > arr[i - 1] and arr[i] > arr[i - 2] \
           and arr[i] > arr[i + 1] and arr[i] > arr[i + 2] \
           and arr[i] > threshold:
            peaks.append((i, arr[i]))
    return sorted(peaks, key=lambda x: -x[1])  # by amplitude desc


def amplitude_from_pulse(pulse_sec, period_sec, lift_deg, lower_gate=60):
    if pulse_sec <= 0 or period_sec <= 0:
        return None
    ratio = pulse_sec / period_sec
    if ratio <= 0.001 or ratio >= 0.25:
        return None
    s = math.sin(math.pi * ratio)
    if s < 1e-10:
        return None
    a = lift_deg / (2.0 * s)
    return a if lower_gate <= a <= 360 else None


def analyze_class(shape, sr, half_ms, period_sec, lift_deg, label):
    """For one class shape: find sub-events, compute amplitude candidates."""
    half_samp = int(half_ms * sr / 1000.0)
    peaks = find_peaks(shape)
    if not peaks:
        return None

    # Convert peak indices to ms relative to argmax (which is at idx=half_samp).
    peaks_ms = [(idx - half_samp) * 1000.0 / sr for idx, _ in peaks]
    peaks_amp = [amp for _, amp in peaks]

    # Reject peaks within ±3 ms of the dominant (those are usually sampling
    # ripple on top of the main peak, not real sub-events). Real Swiss
    # sub-events sit 5-15 ms from the dominant.
    nearby = [
        (t, a) for t, a in zip(peaks_ms, peaks_amp)
        if 3.0 <= abs(t) <= 25.0
    ]
    if len(nearby) < 1:
        return None

    # Sort by amplitude descending and take the 2 strongest non-dominant peaks.
    top = sorted(nearby, key=lambda x: -x[1])[:2]
    positions = sorted([t for t, _ in top])
    amps = [a for _, a in top]

    # All detected peaks for diagnostic visibility (filtered to >3ms from dom).
    nearby_diag = [(t, a) for t, a in zip(peaks_ms, peaks_amp) if 3.0 <= abs(t) <= 25.0]
    nearby_diag = sorted(nearby_diag, key=lambda x: x[0])  # by position
    all_peaks_str = ", ".join(f"{t:+.1f}ms({a:.3f})" for t, a in nearby_diag)

    # Tim's "top-2 × ratio" approach:
    # 1. Take the two biggest peaks in the per-class shape — this is robust
    #    to noise because the loudest events stand out clearest.
    # 2. The spacing between them is one of the inter-sub-event intervals.
    # 3. Multiply by the empirical ratio (~1.6) to estimate the full
    #    unlock-to-lock pulse width.
    #
    # The dominant peak (peak-aligned to 0) is always one of the top 2.
    # The other is the loudest secondary, which on Swiss escapements is
    # typically the drop event. The dom-to-drop spacing is one half of
    # the unlock-to-lock pulse (asymmetrically — typical ratio 1.5–1.7
    # from empirical data on Omega 485). So:
    #
    #   pulse_full ≈ 1.6 × dom-to-loudest-secondary
    #
    # Failure mode (Tim acknowledged): if there are only 2 visible peaks
    # (dom + one secondary that's actually the FAR event, not the close
    # drop), this overestimates. Happens at positions where the drop is
    # acoustically masked. Use the visible-peak count as a confidence
    # indicator.

    # Exclude dominant decay tail (±5 ms) and far noise (> 25 ms).
    nonDecay = [(t, a) for t, a in zip(peaks_ms, peaks_amp)
                if 5.0 <= abs(t) <= 25.0]
    if not nonDecay:
        return None

    # Cluster the peaks into distinct sub-events (peaks within 2 ms are
    # the same physical event seen at multiple sample positions).
    clustered = []  # (center_ms, max_amp)
    for t, a in sorted(nonDecay, key=lambda x: x[0]):
        if clustered and abs(t - clustered[-1][0]) < 2.0:
            # Merge with last cluster, keep highest amplitude.
            ct, ca = clustered[-1]
            if a > ca:
                clustered[-1] = (t, a)
        else:
            clustered.append((t, a))

    # Filter out spurious noise clusters: keep only those with amp >= 3% of
    # dominant. Below that they're likely envelope noise on a low-SNR
    # recording, not real sub-events.
    significant = [(t, a) for t, a in clustered if a >= 0.03]
    n_distinct = len(significant)

    # Heuristic for full pulse based on what's visible:
    #   - Two or more distinct secondaries visible (n>=2): FARTHEST is the
    #     unlock event. Use its distance directly (no multiplier).
    #   - Only one secondary visible (n==1): we don't know if it's the
    #     middle (drop) or far (unlock). Use its distance:
    #       * If spacing < 14 ms: probably the middle event (drop), so
    #         multiply by 1.6 to extrapolate to full unlock-to-lock.
    #       * If spacing > 14 ms: probably the far event (unlock), use
    #         directly (multiplier = 1.0).
    #   - No significant secondaries (n==0): can't measure, return nil.
    candidates = []
    if n_distinct >= 2:
        farthest = max(significant, key=lambda x: abs(x[0]))
        pulse_ms = abs(farthest[0])
        method = f"far/{n_distinct}peaks"
    elif n_distinct == 1:
        spacing = abs(significant[0][0])
        if spacing < 14.0:
            pulse_ms = 1.6 * spacing
            method = f"close×1.6 (1 peak at {spacing:.1f}ms)"
        else:
            pulse_ms = spacing
            method = f"far direct (1 peak at {spacing:.1f}ms)"
    else:
        return None

    amp = amplitude_from_pulse(pulse_ms / 1000.0, period_sec, lift_deg, lower_gate=40)
    if amp is not None:
        candidates.append((pulse_ms, amp, method))

    return {
        "label": label,
        "peaks_ms": positions,
        "peaks_amp": amps,
        "candidates": candidates,
        "all_peaks_str": all_peaks_str,
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: per_class_amplitude.py <reference.json> [<reference.json> ...]")
        sys.exit(1)

    lift_deg = 52.0
    print(f"{'file':<22} {'method: dominant=lock, pulse=unlock-to-lock'}")
    print("-" * 80)

    for path_str in sys.argv[1:]:
        path = Path(path_str)
        with path.open() as f:
            data = json.load(f)

        sr = data["shapeSampleRate"]
        half_ms = data["shapeHalfMs"]
        period_sec = data["regSlopeMs"] / 1000.0

        even = analyze_class(data["evenShape"], sr, half_ms, period_sec, lift_deg, "even")
        odd = analyze_class(data["oddShape"], sr, half_ms, period_sec, lift_deg, "odd")

        def fmt(c):
            if c is None or not c["candidates"]:
                return ("-", None)
            spacing, amp, _ = c["candidates"][0]
            return (f"{spacing:.1f}ms→{amp:.0f}°", amp)

        ev_str, ev_amp = fmt(even)
        od_str, od_amp = fmt(odd)

        if ev_amp is not None and od_amp is not None:
            avg = f"{(ev_amp + od_amp)/2:.0f}°"
        elif ev_amp is not None:
            avg = f"{ev_amp:.0f}°(t)"
        elif od_amp is not None:
            avg = f"{od_amp:.0f}°(o)"
        else:
            avg = "-"

        name = path.stem.replace(".reference", "")
        ev_peaks = even and even["all_peaks_str"] or "-"
        print(f"{name:<22} tick {ev_str:<14}  peaks: {ev_peaks}")
        if odd:
            print(f"{'':<22} tock {od_str:<14}  peaks: {odd['all_peaks_str']}")
        print(f"{'':<22} avg: {avg}")


if __name__ == "__main__":
    main()
