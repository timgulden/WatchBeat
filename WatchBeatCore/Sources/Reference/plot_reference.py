#!/usr/bin/env python3
"""
Plot residuals from the Reference picker output (`<file>.reference.json`).

Two panels:
  Top  — residuals vs beat index, even/odd colored. This is what you'd see
         in a "timegraph": a tick that physically can't move 10 ms in one
         beat but appears to do so in the picker output is an artifact, not
         the watch.
  Bot  — residuals vs absolute time, same data. Useful for spotting drifts
         that correlate with recording position rather than beat index.

Annotations: regression rate, even/odd means ± 1σ, asymmetry value.
"""
import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt


def main():
    if len(sys.argv) < 2:
        print("Usage: plot_reference.py <file.reference.json>")
        sys.exit(1)

    path = Path(sys.argv[1])
    with path.open() as f:
        data = json.load(f)

    beats = data["beats"]
    even_i = [b["index"] for b in beats if b["isEven"]]
    even_t = [b["timeSec"] for b in beats if b["isEven"]]
    even_r = [b["residualMs"] for b in beats if b["isEven"]]
    odd_i = [b["index"] for b in beats if not b["isEven"]]
    odd_t = [b["timeSec"] for b in beats if not b["isEven"]]
    odd_r = [b["residualMs"] for b in beats if not b["isEven"]]

    even_mean = data["evenMean"]
    odd_mean = data["oddMean"]
    asym = data["beAsymmetry"]
    rate_err = data["regRateErrPerDay"]
    nearest = data["nearestRateName"]

    fig = plt.figure(figsize=(12, 10))
    gs = fig.add_gridspec(3, 1, height_ratios=[1, 1, 1])
    ax_idx = fig.add_subplot(gs[0])
    ax_t = fig.add_subplot(gs[1], sharey=ax_idx)
    ax_shape = fig.add_subplot(gs[2])
    axes = [ax_idx, ax_t]
    title = (
        f"{data['fileName']}  —  Reference picker  "
        f"({nearest} bph, {rate_err:+.1f} s/day, asymmetry {asym:.2f} ms)"
    )
    fig.suptitle(title, fontsize=11)

    # Panel 1: residuals vs beat index
    ax = axes[0]
    ax.scatter(even_i, even_r, s=18, c="C0", label=f"even (n={len(even_i)}, μ={even_mean:+.2f} ms)")
    ax.scatter(odd_i, odd_r, s=18, c="C3", label=f"odd  (n={len(odd_i)}, μ={odd_mean:+.2f} ms)")
    ax.axhline(0, color="gray", lw=0.5)
    ax.axhline(even_mean, color="C0", lw=0.5, ls="--", alpha=0.6)
    ax.axhline(odd_mean, color="C3", lw=0.5, ls="--", alpha=0.6)
    ax.set_xlabel("beat index")
    ax.set_ylabel("residual (ms)")
    ax.legend(loc="best", fontsize=9)
    ax.grid(alpha=0.3)

    # Panel 2: residuals vs time
    ax = axes[1]
    ax.scatter(even_t, even_r, s=18, c="C0", label="even")
    ax.scatter(odd_t, odd_r, s=18, c="C3", label="odd")
    ax.axhline(0, color="gray", lw=0.5)
    ax.axhline(even_mean, color="C0", lw=0.5, ls="--", alpha=0.6)
    ax.axhline(odd_mean, color="C3", lw=0.5, ls="--", alpha=0.6)
    ax.set_xlabel("time (s)")
    ax.set_ylabel("residual (ms)")
    ax.grid(alpha=0.3)

    # Panel 3: per-class shape, argmax-aligned (Test 2)
    even_shape = data["evenShape"]
    odd_shape = data["oddShape"]
    sr = data["shapeSampleRate"]
    half_ms = data["shapeHalfMs"]
    n_shape = len(even_shape)
    # Time axis in ms, centered at argmax (= 0).
    half_n = n_shape // 2
    t_ms = [(k - half_n) * 1000.0 / sr for k in range(n_shape)]
    rms = data["shapeRmsDiff"]

    ax_shape.plot(t_ms, even_shape, color="C0", lw=1.5, label="even (tick) class avg")
    ax_shape.plot(t_ms, odd_shape, color="C3", lw=1.5, label="odd (tock) class avg")
    ax_shape.fill_between(t_ms, even_shape, odd_shape,
                          where=[a > b for a, b in zip(even_shape, odd_shape)],
                          color="C0", alpha=0.15)
    ax_shape.fill_between(t_ms, even_shape, odd_shape,
                          where=[a < b for a, b in zip(even_shape, odd_shape)],
                          color="C3", alpha=0.15)
    ax_shape.axvline(0, color="gray", lw=0.5)
    ax_shape.set_xlabel("time relative to per-beat argmax (ms)")
    ax_shape.set_ylabel("envelope (peak-normalized)")
    ax_shape.set_title(
        f"Test 2: per-class average shape, argmax-aligned, peak-normalized.  "
        f"Shape RMS diff = {rms:.4f}  "
        f"(0 = identical → real beat error;  ≥0.05 = different → picker artifact)",
        fontsize=10,
    )
    ax_shape.legend(loc="best", fontsize=9)
    ax_shape.grid(alpha=0.3)

    plt.tight_layout()
    out = path.with_suffix(".png")
    plt.savefig(out, dpi=110)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
