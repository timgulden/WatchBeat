#!/usr/bin/env python3
"""Plot the onset timeline produced by OnsetTimeline.

Usage:
    python3 plot_onset_timeline.py <timeline.json> [<out.png>]

The plot is intentionally wide (one frame, no wrapping) so the eye
can scan whether trimmed picks correspond to amplitude dips, cluttered
sub-event regions, or visibly off-period events.

Layout:
    - Top: filtered/smoothed envelope as a thin line.
    - Below the envelope: vertical mark for every pick at its tick time.
        - Solid blue: kept tick (even beat index).
        - Solid red: kept tock (odd beat index).
        - Open blue circle: trimmed tick.
        - Open red circle: trimmed tock.
    - Thin gray vertical lines: window boundaries (midpoints between
      adjacent predicted tick positions).
"""
import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


def main():
    if len(sys.argv) < 2:
        print("usage: plot_onset_timeline.py <timeline.json> [<out.png>]")
        sys.exit(1)

    path = Path(sys.argv[1])
    with open(path) as f:
        data = json.load(f)

    out_path = sys.argv[2] if len(sys.argv) > 2 else path.with_suffix(".png")

    duration = data["duration"]
    env = np.array(data["envelope"]["samples"], dtype=np.float64)
    env_rate = data["envelope"]["sampleRate"]
    env_t = np.arange(len(env)) / env_rate

    # Normalize envelope to [0, 1] so the plot's y axis is comparable
    # across recordings. Tick lanes go below zero so they don't overlap.
    if env.max() > 0:
        env = env / env.max()

    picks = data["picks"]
    boundaries = data["windowBoundaries"]

    # Figure: ~2 inches per second (so 30 inches for 15 seconds), short height.
    width_in = max(20.0, duration * 2.0)
    fig, ax = plt.subplots(figsize=(width_in, 4.5))

    # Envelope line. Use light fill so the eye sees amplitude shape.
    ax.fill_between(env_t, 0, env, color="#888", alpha=0.6, linewidth=0)
    ax.plot(env_t, env, color="#222", linewidth=0.5)

    # Window boundaries as thin gray vertical lines spanning whole plot.
    for b in boundaries:
        ax.axvline(b, color="#cccccc", linewidth=0.4, zorder=0)

    # Tick lane: at y = -0.15. Plot one mark per pick.
    lane_y = -0.18
    tick_color = "#2c66d8"  # blue
    tock_color = "#d84a4a"  # red
    tick_kept_size = 60
    tick_trimmed_size = 60
    for p in picks:
        t = p["time"]
        c = tick_color if p["isEvenBeat"] else tock_color
        if p["kept"]:
            ax.scatter([t], [lane_y], marker='o', s=tick_kept_size,
                       facecolor=c, edgecolor=c, linewidth=0.8, zorder=3)
        else:
            ax.scatter([t], [lane_y], marker='o', s=tick_trimmed_size,
                       facecolor='none', edgecolor=c, linewidth=1.2, zorder=3)

    # Legend manually (avoid matplotlib auto-legend duplicates).
    legend_y = -0.35
    legend_entries = [
        (0.5,  tick_color, True,  "kept tick"),
        (1.5,  tick_color, False, "trimmed tick"),
        (2.5,  tock_color, True,  "kept tock"),
        (3.5,  tock_color, False, "trimmed tock"),
    ]
    for x, c, kept, label in legend_entries:
        if kept:
            ax.scatter([x], [legend_y], marker='o', s=80,
                       facecolor=c, edgecolor=c, linewidth=0.8, zorder=4,
                       transform=ax.get_xaxis_transform() if False else ax.transData,
                       clip_on=False)
        else:
            ax.scatter([x], [legend_y], marker='o', s=80,
                       facecolor='none', edgecolor=c, linewidth=1.2, zorder=4,
                       clip_on=False)
        ax.text(x + 0.12, legend_y, label, fontsize=9, va="center", clip_on=False)

    # Annotations.
    be = data["beatErrorMs"]
    be_str = "—" if be is None else f"{be:.2f} ms"
    title = (
        f"{data['fileName']}  —  {data['snappedRateBph']} bph  "
        f"rate={data['rateError']:+.1f} s/day  "
        f"BE={be_str}  "
        f"q={int(data['qualityScore']*100)}%  "
        f"kept={data['keptPicks']}/{data['totalPicks']}"
    )
    ax.set_title(title, fontsize=11, loc="left")
    ax.set_xlim(0, duration)
    ax.set_ylim(-0.45, 1.1)
    ax.set_xlabel("seconds", fontsize=9)
    ax.set_yticks([])
    ax.tick_params(axis="x", labelsize=8)
    for spine in ("top", "right", "left"):
        ax.spines[spine].set_visible(False)
    ax.spines["bottom"].set_color("#888")
    ax.spines["bottom"].set_linewidth(0.5)

    plt.tight_layout()
    plt.savefig(out_path, dpi=140, bbox_inches="tight")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
