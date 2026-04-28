#!/usr/bin/env python3
"""Plot per-tick traces with picker-candidate markers (argmax / centroid /
onset@20% / onset@5σ) overlaid for visual stability comparison.

Usage:
  python3 plot_onsets.py <basename>.onsets.json [<basename2>.onsets.json ...]

For each input writes <basename>.onsets.png with two rows (TICK / TOCK):
  left: 30+ individual envelopes overlaid, normalized to their own peak,
        with vertical markers at each candidate position.
  middle: scatter of (beat_index, candidate_offset_ms) for centroid vs
          two onset variants — drift visualizes which detector slides.
  right: histogram of inter-tick spacing residuals (offset minus its mean)
         for centroid vs onset@20%, in ms.
"""
import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


def panel_for_class(axes, traces, label, beat_period_ms, sample_rate):
    ax_overlay, ax_scatter, ax_hist = axes
    if not traces:
        for a in axes:
            a.text(0.5, 0.5, f"no {label} traces", ha="center", va="center",
                   transform=a.transAxes, color="#888")
            a.set_xticks([]); a.set_yticks([])
        return

    half_ms = traces[0]["env_half_ms"]
    n_pts = len(traces[0]["env"])
    t_axis = np.linspace(-half_ms, half_ms, n_pts)

    # Convert per-tick (beat_index, offset_ms_from_anchor) into per-tick
    # absolute time in ms so that downstream spacing comparisons are fair —
    # the anchor itself jitters tick-to-tick, so offsets-from-anchor would
    # make any detector that's *not* the anchor look noisy.
    def abs_ms(tr, key):
        v = tr.get(key)
        if v is None: return None
        return tr["center_sample_abs"] / sample_rate * 1000.0 + v

    # Overlay: each tick's envelope (blue, translucent) and spectral-flux
    # detection function (purple, translucent), each normalized to its own
    # peak so shapes are comparable across ticks. Markers above show where
    # each detector thinks the tick is.
    # We keep TWO sets of pairs per detector:
    #   *_offset_pairs: (beat_index, offset_ms_from_anchor) — for the
    #                   marker rugs and the offset-vs-time scatter.
    #   *_abs_pairs:    (beat_index, absolute_time_ms) — for the spacing
    #                   residual histogram, which must use absolute
    #                   positions or the anchor's own jitter contaminates
    #                   the comparison.
    centroid_offset, on20_offset, on5_offset = [], [], []
    flux_peak_offset, flux_onset_offset, flux_first_offset = [], [], []
    centroid_abs, on20_abs, on5_abs = [], [], []
    flux_peak_abs, flux_onset_abs, flux_first_abs = [], [], []
    anchor_abs = []
    for tr in traces:
        env = np.asarray(tr["env"], dtype=float)
        peak = env.max() if env.size else 0
        if peak > 0:
            ax_overlay.plot(t_axis, env / peak, color="#1f77b4", lw=0.4, alpha=0.18)
        flux = np.asarray(tr.get("flux", []), dtype=float)
        if flux.size and flux.max() > 0:
            ax_overlay.plot(t_axis, flux / flux.max(), color="#9467bd", lw=0.5, alpha=0.20)
        b = tr["beat_index"]
        anchor_abs.append((b, tr["center_sample_abs"] / sample_rate * 1000.0))
        for key, off, ab in (
            ("centroid_ms",      centroid_offset,   centroid_abs),
            ("onset_20pct_ms",   on20_offset,       on20_abs),
            ("onset_5sigma_ms",  on5_offset,        on5_abs),
            ("flux_peak_ms",     flux_peak_offset,  flux_peak_abs),
            ("flux_onset_ms",    flux_onset_offset, flux_onset_abs),
            ("flux_first_ms",    flux_first_offset, flux_first_abs),
        ):
            v = tr.get(key)
            if v is not None:
                off.append((b, v))
                ab.append((b, abs_ms(tr, key)))

    # Marker rug-bands at six different y positions so we can see overlap.
    for pairs, color, y, name in (
        (centroid_offset,   "#d62728", 1.05, "centroid"),
        (on20_offset,       "#2ca02c", 1.10, "onset 20%"),
        (on5_offset,        "#ff7f0e", 1.15, "onset 5σ"),
        (flux_peak_offset,  "#9467bd", 1.20, "flux peak"),
        (flux_onset_offset, "#1f6e1f", 1.25, "flux onset"),
        (flux_first_offset, "#000000", 1.30, "flux first"),
    ):
        if pairs:
            xs = [v for _, v in pairs]
            ax_overlay.scatter(xs, [y] * len(xs), s=12, color=color,
                               alpha=0.55, edgecolors="none", label=name)
    ax_overlay.set_xlim(-half_ms, half_ms)
    ax_overlay.set_ylim(0, 1.40)
    ax_overlay.axvline(0, color="#bbbbbb", lw=0.5)
    ax_overlay.set_xlabel("time relative to argmax anchor (ms)")
    ax_overlay.set_ylabel("normalized envelope (blue) / flux (purple)")
    ax_overlay.set_title(f"{label}: per-tick envelopes + spectral flux (n={len(traces)})", loc="left", fontsize=9)
    ax_overlay.grid(True, alpha=0.3)
    ax_overlay.legend(loc="upper right", fontsize=7, ncol=3, frameon=False)

    # Scatter: candidate offsets vs beat_index. A stable detector is flat
    # (apart from real watch rate effects); a drifting detector wanders.
    def scatter(pairs, color, name):
        if not pairs: return
        ax_scatter.scatter([p[0] for p in pairs], [p[1] for p in pairs],
                           s=10, color=color, alpha=0.6,
                           edgecolors="none", label=name)
    scatter(centroid_offset,   "#d62728", "centroid")
    scatter(on20_offset,       "#2ca02c", "onset 20%")
    scatter(on5_offset,        "#ff7f0e", "onset 5σ")
    scatter(flux_peak_offset,  "#9467bd", "flux peak")
    scatter(flux_onset_offset, "#1f6e1f", "flux onset")
    scatter(flux_first_offset, "#000000", "flux first")
    ax_scatter.axhline(0, color="#bbbbbb", lw=0.5)
    ax_scatter.set_xlabel("beat index")
    ax_scatter.set_ylabel("offset from argmax (ms)")
    ax_scatter.set_title(f"{label}: candidate offset over time", loc="left", fontsize=9)
    ax_scatter.grid(True, alpha=0.3)
    ax_scatter.legend(loc="upper right", fontsize=7, frameon=False)

    # Histogram: tick-to-tick spacing residuals. Use the *differences* of
    # successive picks (sorted by beat_index), minus the mean spacing for
    # this detector, scaled to ms. A jitter-free detector clusters at zero.
    def spacing_residuals(pairs):
        if len(pairs) < 4: return np.array([])
        s = sorted(pairs, key=lambda p: p[0])
        idx = np.array([p[0] for p in s])
        v = np.array([p[1] for p in s])
        di = np.diff(idx)
        dv = np.diff(v)
        per_beat = dv / np.where(di > 0, di, 1)
        return per_beat - per_beat.mean() if per_beat.size else per_beat

    # Histogram uses *absolute* tick times so the comparison is fair —
    # spacing residuals are (delta_absolute_time / delta_beat - mean_period).
    # Include the raw anchor (smoothed-envelope argmax) as a reference baseline.
    bins = np.linspace(-3, 3, 41)
    for pairs, color, name in (
        (anchor_abs,        "#1f77b4", "anchor (argmax)"),
        (centroid_abs,      "#d62728", "centroid"),
        (on20_abs,          "#2ca02c", "onset 20%"),
        (on5_abs,           "#ff7f0e", "onset 5σ"),
        (flux_peak_abs,     "#9467bd", "flux peak"),
        (flux_onset_abs,    "#1f6e1f", "flux onset"),
        (flux_first_abs,    "#000000", "flux first"),
    ):
        r = spacing_residuals(pairs)
        if r.size:
            ax_hist.hist(r, bins=bins, color=color, alpha=0.35,
                         label=f"{name} σ={r.std():.2f}ms")
    ax_hist.set_xlabel("spacing residual per beat (ms)")
    ax_hist.set_ylabel("count")
    ax_hist.set_title(f"{label}: inter-tick spacing residuals", loc="left", fontsize=9)
    ax_hist.grid(True, alpha=0.3)
    ax_hist.legend(loc="upper right", fontsize=7, frameon=False)
    ax_hist.axvline(0, color="#bbbbbb", lw=0.5)


def beat_error_diagnostic(ticks, tocks, sample_rate, beat_period_ms):
    """For each detector, fit a line to absolute positions vs beat_index
    using ticks AND tocks together, then split residuals by class. A
    consistent beat error shows as: (a) tick mean residual = -tock mean
    residual, (b) both with low std relative to the mean. A picker that
    sub-event-flips between ticks and tocks shows large |tick mean - tock
    mean| AND large per-class std.

    Returns a dict {detector_name: (tick_mean_ms, tock_mean_ms,
                                    tick_std_ms, tock_std_ms, n_ticks, n_tocks)}.
    """
    detectors = [
        ("anchor",    "center_sample_abs", lambda tr: tr["center_sample_abs"] / sample_rate * 1000.0),
        ("centroid",  "centroid_ms",       None),
        ("onset 20%", "onset_20pct_ms",    None),
        ("onset 5σ",  "onset_5sigma_ms",   None),
        ("flux peak", "flux_peak_ms",      None),
        ("flux onset","flux_onset_ms",     None),
        ("flux first","flux_first_ms",     None),
        ("matched",   "matched_ms",        None),
    ]
    out = {}
    for name, key, custom in detectors:
        def get(tr):
            if custom is not None: return custom(tr)
            v = tr.get(key)
            if v is None: return None
            return tr["center_sample_abs"] / sample_rate * 1000.0 + v

        # Combined fit on (beat_index, abs_time_ms) using both classes.
        all_pts = []
        for tr in ticks + tocks:
            v = get(tr)
            if v is None: continue
            all_pts.append((tr["beat_index"], v, tr.get("is_even", False)))
        if len(all_pts) < 6:
            continue
        bi = np.array([p[0] for p in all_pts], dtype=float)
        v = np.array([p[1] for p in all_pts], dtype=float)
        even_mask = np.array([p[2] for p in all_pts], dtype=bool)
        # OLS on (bi, v).
        slope, intercept = np.polyfit(bi, v, 1)
        residuals = v - (slope * bi + intercept)
        tick_r = residuals[even_mask]
        tock_r = residuals[~even_mask]
        if tick_r.size and tock_r.size:
            out[name] = (
                float(tick_r.mean()), float(tock_r.mean()),
                float(tick_r.std()),  float(tock_r.std()),
                int(tick_r.size),     int(tock_r.size),
            )
    return out


def plot_one(json_path: Path) -> None:
    data = json.loads(json_path.read_text())
    fig = plt.figure(figsize=(15, 9))
    # Three rows: TICK panel, TOCK panel, beat-error diagnostic table.
    gs = fig.add_gridspec(3, 3, width_ratios=[2.2, 1.6, 1.4],
                          height_ratios=[3, 3, 1.6])
    fig.suptitle(
        f"{data['file']}  —  {data['bph']} bph  period={data['beat_period_ms']:.2f}ms",
        fontsize=11,
    )
    sample_rate = data["sample_rate"]
    panel_for_class(
        [fig.add_subplot(gs[0, 0]), fig.add_subplot(gs[0, 1]), fig.add_subplot(gs[0, 2])],
        data.get("ticks", []), "TICK (even beats)", data["beat_period_ms"], sample_rate
    )
    panel_for_class(
        [fig.add_subplot(gs[1, 0]), fig.add_subplot(gs[1, 1]), fig.add_subplot(gs[1, 2])],
        data.get("tocks", []), "TOCK (odd beats)", data["beat_period_ms"], sample_rate
    )

    # Beat-error diagnostic: for each detector, show tick and tock mean
    # residuals as a horizontal bar (tick above zero, tock below) with
    # error bars for per-class std. The visual signature of a consistent
    # beat error is symmetric bars (tick = -tock) with small error bars.
    # Sub-event-flipping shows asymmetric or noisy bars.
    ax_diag = fig.add_subplot(gs[2, :])
    diag = beat_error_diagnostic(
        data.get("ticks", []), data.get("tocks", []),
        sample_rate, data["beat_period_ms"]
    )
    if diag:
        names = list(diag.keys())
        x = np.arange(len(names))
        tick_means = np.array([diag[n][0] for n in names])
        tock_means = np.array([diag[n][1] for n in names])
        tick_stds  = np.array([diag[n][2] for n in names])
        tock_stds  = np.array([diag[n][3] for n in names])
        width = 0.35
        ax_diag.bar(x - width/2, tick_means, width, yerr=tick_stds,
                    color="#d62728", alpha=0.7, label="tick mean residual",
                    capsize=4, error_kw=dict(lw=0.8))
        ax_diag.bar(x + width/2, tock_means, width, yerr=tock_stds,
                    color="#2ca02c", alpha=0.7, label="tock mean residual",
                    capsize=4, error_kw=dict(lw=0.8))
        # Annotate consistent-beat-error metric: half the |tick - tock|
        # difference, which is the classical timegrapher "beat error"
        # number for that detector.
        for xi, n in zip(x, names):
            be = abs(diag[n][0] - diag[n][1]) / 2.0
            ax_diag.text(xi, max(tick_means[xi], tock_means[xi]) + 0.5,
                         f"BE={be:.2f}ms", ha="center", va="bottom", fontsize=8)
        ax_diag.set_xticks(x)
        ax_diag.set_xticklabels(names, fontsize=9)
        ax_diag.axhline(0, color="#888", lw=0.6)
        ax_diag.set_ylabel("residual from joint regression (ms)")
        ax_diag.set_title(
            "Beat-error diagnostic: tick vs tock mean residual (low |tick−tock| spread = consistent beat error; "
            "narrow error bars = same sub-event picked every time)",
            loc="left", fontsize=9,
        )
        ax_diag.legend(loc="upper right", fontsize=8, frameon=False)
        ax_diag.grid(True, axis="y", alpha=0.3)
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    out = json_path.with_suffix(".png")
    # Avoid clobbering the .anatomy.png — write to <base>.onsets.png explicitly.
    out = json_path.parent / (json_path.stem + ".png")
    fig.savefig(out, dpi=140)
    plt.close(fig)
    print(f"wrote {out}")


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
