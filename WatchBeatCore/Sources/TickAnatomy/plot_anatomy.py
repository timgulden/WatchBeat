#!/usr/bin/env python3
"""Plot TickAnatomy output: averaged waveform + envelopes for tick and tock,
with phase peaks, pulse-width edges, and onset edges marked.

Usage:
  python3 plot_anatomy.py <basename>.anatomy.csv [<basename2>.anatomy.csv ...]
  python3 plot_anatomy.py *.anatomy.csv

Reads <basename>.anatomy.json sidecar for the overlay positions. Writes
<basename>.anatomy.png next to each CSV.
"""
import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


def plot_one(csv_path: Path) -> None:
    json_path = csv_path.with_suffix(".json")
    if not json_path.exists():
        print(f"skip {csv_path.name}: no sidecar {json_path.name}", file=sys.stderr)
        return

    data = np.genfromtxt(csv_path, delimiter=",", names=True)
    meta = json.loads(json_path.read_text())

    t = data["time_ms"]

    # Two rows of waveform+envelopes, plus two histogram panels on the right
    fig = plt.figure(figsize=(15, 7))
    gs = fig.add_gridspec(2, 3, width_ratios=[2.5, 2.5, 1.0])
    axes = [fig.add_subplot(gs[0, :2]), fig.add_subplot(gs[1, :2])]
    hist_axes = [fig.add_subplot(gs[0, 2]), fig.add_subplot(gs[1, 2])]
    axes[0].sharex(axes[1])
    fig.suptitle(
        f"{meta['file']}  —  {meta['bph']} bph  q={meta['quality']}%  "
        f"period={meta['beat_period_ms']:.1f}ms  lift={meta['lift_angle_deg']:.0f}°",
        fontsize=11,
    )

    for ax, hax, name, wf_col, fine_col, mid_col, pulse_col, meas_key, ptvac_key in (
        (axes[0], hist_axes[0], "TICK (even beats)", "tick_waveform", "tick_env_fine", "tick_env_mid", "tick_env_pulse", "tick", "tick_per_tick_vacaboja"),
        (axes[1], hist_axes[1], "TOCK (odd beats)",  "tock_waveform", "tock_env_fine", "tock_env_mid", "tock_env_pulse", "tock", "tock_per_tick_vacaboja"),
    ):
        wf = data[wf_col]
        fine = data[fine_col]
        mid = data[mid_col]
        pulse = data[pulse_col]
        m = meta.get(meas_key)

        # Normalize waveform peak to ±1 for display
        wf_peak = np.max(np.abs(wf)) if np.any(wf) else 1.0
        if wf_peak == 0:
            wf_peak = 1.0
        ax.plot(t, wf / wf_peak, color="#bbbbbb", lw=0.6, label="waveform (normalized)")

        # Envelopes, all normalized to their own peak so shape comparison is fair
        if np.max(fine) > 0:
            ax.plot(t, fine / np.max(fine), color="#1f77b4", lw=1.0, alpha=0.9, label="env 0.15ms")
        if np.max(mid) > 0:
            ax.plot(t, mid / np.max(mid), color="#9467bd", lw=1.5, label="env 1ms")
        if np.max(pulse) > 0:
            ax.plot(t, pulse / np.max(pulse), color="#ff7f0e", lw=1.2, alpha=0.8, label="env 3ms")

        # Overlays
        if m is not None:
            # Phase peaks
            for i, (tms, arel) in enumerate(zip(m.get("phase_peaks_ms") or [], m.get("phase_amps_rel") or [])):
                ax.axvline(tms, color="#d62728", ls=":", lw=1)
                ax.text(tms, 1.05 + 0.07 * (i % 2), f"{i+1}", color="#d62728",
                        ha="center", va="bottom", fontsize=9, fontweight="bold")

            # Pulse-width bands for each smoothing
            ml, mt = m.get("mid_lead_ms"), m.get("mid_trail_ms")
            if ml is not None and mt is not None:
                ax.axvspan(ml, mt, color="#9467bd", alpha=0.14, label="1ms pulse (20%)")
            pl, pt = m.get("pulse_lead_ms"), m.get("pulse_trail_ms")
            if pl is not None and pt is not None:
                ax.axvspan(pl, pt, color="#ff7f0e", alpha=0.10, label="3ms pulse (20%)")
            ol, ot = m.get("onset_lead_ms"), m.get("onset_trail_ms")
            if ol is not None and ot is not None:
                ax.axvspan(ol, ot, color="#2ca02c", alpha=0.10, label="onset (5σ)")

            # Amplitudes into the legend
            phase_amp = m.get("phase_amp_deg")
            mid_amp   = m.get("mid_amp_deg")
            pulse_amp = m.get("pulse_amp_deg")
            onset_amp = m.get("onset_amp_deg")
            parts = []
            parts.append(f"phase: {phase_amp:.0f}°" if phase_amp is not None else "phase: —")
            parts.append(f"1ms: {mid_amp:.0f}°"     if mid_amp   is not None else "1ms: —")
            parts.append(f"3ms: {pulse_amp:.0f}°"   if pulse_amp is not None else "3ms: —")
            parts.append(f"onset: {onset_amp:.0f}°" if onset_amp is not None else "onset: —")
            # Also widths so we can see how 1ms vs 3ms compares
            widths = []
            if ml is not None and mt is not None: widths.append(f"1ms w={mt-ml:.2f}ms")
            if pl is not None and pt is not None: widths.append(f"3ms w={pt-pl:.2f}ms")
            text = "   ".join(parts)
            if widths: text += "    (" + "  ".join(widths) + ")"
            ax.text(0.01, 0.97, text, transform=ax.transAxes,
                    ha="left", va="top", fontsize=9,
                    bbox=dict(facecolor="white", edgecolor="#cccccc", alpha=0.85))

        ax.set_title(name, loc="left", fontsize=10)
        ax.axhline(0, color="#eeeeee", lw=0.5)
        ax.set_ylabel("normalized amplitude")
        ax.grid(True, alpha=0.3)
        ax.legend(loc="upper right", fontsize=8)
        ax.set_ylim(-1.15, 1.35)

        # Histogram panel: per-tick vacaboja amplitude distribution.
        # This is the primary per-tick number: each tick runs its own
        # threshold-sweep with 1ms peak-hold envelope, kept if it converges
        # to an amplitude in [135°, 360°]. The distribution gives us what no
        # single-beat timegrapher can: a confidence interval on the reading.
        ptv = meta.get(ptvac_key) or {}
        amps = ptv.get("amps_deg") or []
        if amps:
            hax.hist(amps, bins=20, color="#2ca02c", alpha=0.6,
                     edgecolor="#1f6e1f", linewidth=0.5)
            med = ptv.get("median_amp_deg")
            p25 = ptv.get("p25_amp_deg")
            p75 = ptv.get("p75_amp_deg")
            if med is not None:
                hax.axvline(med, color="#1f6e1f", ls="-", lw=1.5)
            if p25 is not None:
                hax.axvline(p25, color="#1f6e1f", ls=":", lw=1.0)
            if p75 is not None:
                hax.axvline(p75, color="#1f6e1f", ls=":", lw=1.0)

            iqr = None
            if p25 is not None and p75 is not None:
                iqr = p75 - p25
            se = ptv.get("median_stderr_deg")
            lines = [f"n={len(amps)}"]
            if med is not None:
                if se is not None:
                    lines.append(f"med={med:.0f}° ±{se:.1f}°")
                else:
                    lines.append(f"med={med:.0f}°")
            if iqr is not None:
                lines.append(f"IQR={iqr:.0f}°")
            hax.text(0.02, 0.98, "\n".join(lines), transform=hax.transAxes,
                     ha="left", va="top", fontsize=8,
                     bbox=dict(facecolor="white", edgecolor="#cccccc", alpha=0.85))
        else:
            hax.text(0.5, 0.5, "no converged\nper-tick readings",
                     transform=hax.transAxes, ha="center", va="center",
                     fontsize=9, color="#888888")

        hax.set_title(f"per-tick amplitude ({name.split()[0].lower()})", loc="left", fontsize=9)
        hax.set_xlabel("amplitude (°)")
        hax.set_ylabel("count")
        hax.grid(True, alpha=0.3)
        hax.set_xlim(120, 370)

    axes[-1].set_xlabel("time relative to aligned peak (ms)")
    fig.tight_layout(rect=(0, 0, 1, 0.96))

    out_path = csv_path.with_suffix(".png")
    fig.savefig(out_path, dpi=140)
    plt.close(fig)
    print(f"wrote {out_path}")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1
    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.exists():
            print(f"not found: {arg}", file=sys.stderr)
            continue
        plot_one(p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
