#!/usr/bin/env python3
"""
report.py - turn the CSV logs written by the monitors into numbers and graphs.

    python analyze/report.py                 # last 24 hours
    python analyze/report.py --days 7        # last 7 days
    python analyze/report.py --all           # everything in logs/
    python analyze/report.py --show          # also open the graph in a window
    python analyze/report.py --no-plot       # numbers only
    python analyze/report.py --theme dark    # dark graph

Prints a summary (the "table view") and saves a multi-panel PNG to reports/.
Needs pandas and matplotlib (see requirements.txt). This script only does
analysis; the monitoring itself is plain bash.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime
from pathlib import Path

try:
    import pandas as pd
except ImportError:
    sys.exit("pandas is not installed. Run: pip install -r analyze/requirements.txt")

ROOT = Path(__file__).resolve().parent.parent
MIN_SESSION = pd.Timedelta(minutes=10)

# Chart colours: a validated categorical palette (blue, orange) and neutral
# chrome for each theme. Single-series panels use the first colour.
THEMES = {
    "light": dict(surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e", muted="#898781",
                  grid="#e1e0d9", axis="#c3c2b7", s1="#2a78d6", s2="#eb6834"),
    "dark": dict(surface="#1a1a19", ink="#f0efec", ink2="#c3c2b7", muted="#898781",
                 grid="#2c2c2a", axis="#383835", s1="#3987e5", s2="#d95926"),
}

# One panel per measure, so every panel has a single y-axis.
PANELS = [
    dict(src="battery", title="Battery charge", unit="%", cols=[("percent", "Charge")],
         ylim=(0, 100), end_label=True, shade=True),
    dict(src="battery", title="Battery power flow", unit="W", cols=[("power_w", "Power")],
         zero=True, peak=True, shade=True),
    dict(src="cpu", title="CPU temperature", unit="°C", cols=[("temp_c", "Temperature")],
         peak=True),
    dict(src="cpu", title="CPU usage", unit="%", cols=[("usage_pct", "Usage")], ylim=(0, 100)),
    dict(src="cpu", title="CPU frequency", unit="MHz", cols=[("freq_mhz", "Frequency")],
         zero=True),
    dict(src="memory", title="Memory used", unit="%", cols=[("mem_used_pct", "Used")],
         ylim=(0, 100)),
    dict(src="disk", title="Disk throughput", unit="KB/s",
         cols=[("read_kbps", "Read"), ("write_kbps", "Write")], zero=True),
]

# ----------------------------------------------------------------- loading


def load(monitor: str, log_dir: Path, since: pd.Timestamp | None) -> pd.DataFrame:
    """All CSVs of one monitor as one time-sorted frame (local wall-clock time)."""
    frames = []
    for f in sorted((log_dir / monitor).glob("*.csv")):
        try:
            frames.append(pd.read_csv(f, on_bad_lines="skip"))
        except (pd.errors.EmptyDataError, OSError):
            continue
    frames = [f for f in frames if not f.empty and "timestamp" in f]
    if not frames:
        return pd.DataFrame()

    df = pd.concat(frames, ignore_index=True)
    # Timestamps look like 2026-11-23T17:56:00+0530; keep the local wall time.
    df["timestamp"] = pd.to_datetime(
        df["timestamp"].astype(str).str[:19], format="%Y-%m-%dT%H:%M:%S", errors="coerce"
    )
    df = df.dropna(subset=["timestamp"]).sort_values("timestamp")
    df = df.drop_duplicates("timestamp")
    for col in df.columns:
        if col not in ("timestamp", "status"):
            df[col] = pd.to_numeric(df[col], errors="coerce")
    if since is not None:
        df = df[df["timestamp"] >= since]
    return df.reset_index(drop=True)


def break_gaps(df: pd.DataFrame, factor: float = 3.0) -> pd.DataFrame:
    """Insert an empty row inside long logging gaps so lines don't bridge them."""
    if len(df) < 3:
        return df
    dt = df["timestamp"].diff()
    limit = max(dt.median() * factor, pd.Timedelta(minutes=5))
    gaps = df.index[dt > limit]
    if len(gaps) == 0:
        return df
    filler = pd.DataFrame({"timestamp": df.loc[gaps, "timestamp"] - pd.Timedelta(seconds=1)})
    return pd.concat([df, filler], ignore_index=True).sort_values("timestamp").reset_index(drop=True)


# ----------------------------------------------------------------- numbers


def fmt_dur(seconds: float) -> str:
    h, rem = divmod(int(seconds), 3600)
    m = rem // 60
    return f"{h}h {m:02d}m" if h else f"{m}m"


def stat_line(label: str, df: pd.DataFrame, col: str, unit: str = "",
              digits: int = 1, peak: bool = False) -> None:
    if df.empty or col not in df:
        return
    s = df[col].dropna()
    if s.empty:
        return
    text = (f"  {label:<20} avg {s.mean():.{digits}f}{unit}   "
            f"min {s.min():.{digits}f}{unit}   max {s.max():.{digits}f}{unit}")
    if peak:
        text += f"   (peak {df.loc[s.idxmax(), 'timestamp']:%d %b %H:%M})"
    print(text)


def battery_runs(b: pd.DataFrame, status: str) -> list[pd.DataFrame]:
    """Runs of consecutive samples with one status, split at logging gaps."""
    if b.empty or "status" not in b:
        return []
    dt = b["timestamp"].diff()
    limit = pd.Timedelta(minutes=5)
    if len(b) > 2:
        limit = max(dt.median() * 3, limit)
    run_id = ((b["status"] != b["status"].shift()) | (dt > limit)).cumsum()
    return [g for _, g in b.groupby(run_id) if g["status"].iloc[0] == status]


def report_battery(b: pd.DataFrame) -> None:
    print("\n== Battery ==")
    if b.empty:
        print("  no data")
        return
    last = b.iloc[-1]
    print(f"  {len(b)} samples, {b['timestamp'].iloc[0]:%d %b %H:%M} to {last['timestamp']:%d %b %H:%M}")

    pct = b["percent"].dropna() if "percent" in b else pd.Series(dtype=float)
    if not pct.empty:
        print(f"  Now: {pct.iloc[-1]:.0f}% ({last.get('status', '?')})")
    health = b["health_pct"].dropna() if "health_pct" in b else pd.Series(dtype=float)
    if not health.empty:
        print(f"  Health: {health.iloc[-1]:.1f}% of design capacity")
    cycles = b["cycle_count"].dropna() if "cycle_count" in b else pd.Series(dtype=float)
    if not cycles.empty:
        print(f"  Charge cycles: {cycles.iloc[-1]:.0f}")

    dis_runs = battery_runs(b, "Discharging")
    chg_runs = battery_runs(b, "Charging")
    span = lambda runs: sum((g["timestamp"].iloc[-1] - g["timestamp"].iloc[0]).total_seconds() for g in runs)
    print(f"  On battery: {fmt_dur(span(dis_runs))}   Charging: {fmt_dur(span(chg_runs))}")

    rows, tot_drop, tot_hours = [], 0.0, 0.0
    for g in dis_runs:
        dur = g["timestamp"].iloc[-1] - g["timestamp"].iloc[0]
        p = g["percent"].dropna()
        if dur < MIN_SESSION or len(p) < 2:
            continue
        drop, hours = p.iloc[0] - p.iloc[-1], dur.total_seconds() / 3600
        if drop <= 0:
            continue
        tot_drop += drop
        tot_hours += hours
        watts = g["power_w"].mean() if "power_w" in g else float("nan")
        rows.append((g["timestamp"].iloc[0], dur, p.iloc[0], p.iloc[-1], drop / hours, watts))

    if rows:
        print("\n  Discharge sessions (10+ min)")
        print("    start          length   charge        %/hour   avg W   full-charge life")
        for start, dur, p0, p1, rate, watts in rows:
            w = f"{watts:5.1f}" if pd.notna(watts) else "    -"
            print(f"    {start:%d %b %H:%M}   {fmt_dur(dur.total_seconds()):>6}   "
                  f"{p0:3.0f}% -> {p1:3.0f}%   {rate:6.1f}   {w}   ~{100 / rate:.1f} h")
        rate = tot_drop / tot_hours
        print(f"\n  Overall drain rate: {rate:.1f} %/hour  ->  about {100 / rate:.1f} h from a full charge")
    else:
        print("\n  Not enough time on battery yet for a drain rate (needs a 10+ min discharge).")

    on_batt = b.loc[b["status"] == "Discharging", "power_w"].dropna() if "power_w" in b else pd.Series(dtype=float)
    if not on_batt.empty:
        avg_w = on_batt.mean()
        line = f"  Average draw on battery: {avg_w:.1f} W"
        full = b["energy_full_wh"].dropna() if "energy_full_wh" in b else pd.Series(dtype=float)
        if not full.empty and avg_w > 0:
            line += f"  ->  {full.iloc[-1] / avg_w:.1f} h from a full {full.iloc[-1]:.1f} Wh battery"
        print(line)
    stat_line("Power flow", b, "power_w", " W", peak=True)


def report_cpu(c: pd.DataFrame) -> None:
    print("\n== CPU ==")
    if c.empty:
        print("  no data")
        return
    stat_line("Temperature", c, "temp_c", " °C", peak=True)
    stat_line("Usage", c, "usage_pct", " %", peak=True)
    stat_line("Frequency", c, "freq_mhz", " MHz", digits=0)
    stat_line("Load (1 min)", c, "load1", "", digits=2, peak=True)
    stat_line("Fan speed", c, "fan_rpm", " RPM", digits=0)


def report_memory(m: pd.DataFrame) -> None:
    print("\n== Memory ==")
    if m.empty:
        print("  no data")
        return
    stat_line("RAM used", m, "mem_used_pct", " %", peak=True)
    stat_line("RAM available", m, "mem_available_mb", " MB", digits=0)
    stat_line("Swap used", m, "swap_used_mb", " MB", digits=0, peak=True)


def report_disk(d: pd.DataFrame) -> None:
    print("\n== Disk ==")
    if d.empty:
        print("  no data")
        return
    used, avail = d["used_pct"].dropna(), d["avail_gb"].dropna()
    if not used.empty and not avail.empty:
        change = avail.iloc[-1] - avail.iloc[0]
        print(f"  Now: {used.iloc[-1]:.0f}% used, {avail.iloc[-1]:.1f} GB free "
              f"({change:+.1f} GB over this period)")
    stat_line("Read", d, "read_kbps", " KB/s", digits=0, peak=True)
    stat_line("Write", d, "write_kbps", " KB/s", digits=0, peak=True)


# ------------------------------------------------------------------ graphs


def plugged_spans(b: pd.DataFrame):
    """(start, end) of each stretch where the laptop was plugged in."""
    if b.empty:
        return
    if "ac_online" in b and b["ac_online"].notna().any():
        mask = b["ac_online"] == 1
    else:
        mask = b["status"].isin(["Charging", "Full"])
    start, prev = None, None
    for ts, on in zip(b["timestamp"], mask):
        if on and start is None:
            start = ts
        elif not on and start is not None:
            yield start, ts
            start = None
        prev = ts
    if start is not None:
        yield start, prev


def make_graph(data: dict[str, pd.DataFrame], theme: str, out: Path, show: bool) -> Path | None:
    import matplotlib

    if not show:
        matplotlib.use("Agg")
    import matplotlib.dates as mdates
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch

    t = THEMES[theme]
    panels = [
        p for p in PANELS
        if not data[p["src"]].empty
        and any(c in data[p["src"]] and data[p["src"]][c].notna().any() for c, _ in p["cols"])
    ]
    if not panels:
        print("\nNothing to plot yet.")
        return None

    frames = [data[p["src"]] for p in panels]
    x_min = min(f["timestamp"].min() for f in frames)
    x_max = max(f["timestamp"].max() for f in frames)
    if x_min == x_max:
        x_max = x_min + pd.Timedelta(minutes=1)
    span_num = mdates.date2num(x_max) - mdates.date2num(x_min)

    fig = plt.figure(figsize=(11, 1.95 * len(panels) + 0.9), facecolor=t["surface"],
                     layout="constrained")
    axes = fig.subplots(len(panels), 1, sharex=True, squeeze=False)[:, 0]
    fig.suptitle(f"Laptop status  ·  {x_min:%d %b %H:%M} to {x_max:%d %b %H:%M}",
                 x=0.01, ha="left", fontsize=12, color=t["ink"])

    legend_done = False
    for ax, p in zip(axes, panels):
        df = break_gaps(data[p["src"]])
        ax.set_facecolor(t["surface"])
        for side in ("top", "right", "left"):
            ax.spines[side].set_visible(False)
        ax.spines["bottom"].set_color(t["axis"])
        ax.grid(axis="y", color=t["grid"], linewidth=0.6, linestyle="-")
        ax.set_axisbelow(True)
        ax.tick_params(axis="y", length=0, labelsize=8, labelcolor=t["muted"])
        ax.tick_params(axis="x", length=3, color=t["axis"], labelsize=8, labelcolor=t["muted"])
        ax.set_title(p["title"], loc="left", fontsize=10, color=t["ink"], pad=6)
        ax.set_ylabel(p["unit"], rotation=0, ha="right", va="center", fontsize=8,
                      color=t["muted"], labelpad=8)

        # Plugged-in shading (neutral wash, behind the line).
        shade_handle = None
        if p.get("shade"):
            for s, e in plugged_spans(data["battery"]):
                ax.axvspan(s, e, color=t["muted"], alpha=0.16, linewidth=0, zorder=0)
                shade_handle = Patch(facecolor=t["muted"], alpha=0.3, label="Plugged in")

        for i, (col, label) in enumerate(p["cols"]):
            if col not in df or df[col].notna().sum() == 0:
                continue
            color = t["s1"] if i == 0 else t["s2"]
            few = df[col].notna().sum() < 30
            ax.plot(df["timestamp"], df[col], color=color, linewidth=1.6,
                    solid_capstyle="round", label=label,
                    marker="o" if few else None, markersize=3.5,
                    markeredgecolor=t["surface"], markeredgewidth=0.8)

        if "ylim" in p:
            ax.set_ylim(*p["ylim"])
        else:
            ymax = max((df[c].max() for c, _ in p["cols"] if c in df and df[c].notna().any()),
                       default=1)
            if p.get("zero"):
                ax.set_ylim(0, ymax * 1.25 if ymax > 0 else 1)
            else:
                ax.margins(y=0.3)  # headroom so the max label clears the line
        ax.set_xlim(x_min, x_max)

        # Direct labels: only the extreme / end value, never every point.
        def label_point(x, y, text, color):
            y0, y1 = ax.get_ylim()
            above = (y - y0) / (y1 - y0) < 0.9 if y1 > y0 else True
            frac = (mdates.date2num(x) - mdates.date2num(x_min)) / span_num
            ha = "left" if frac < 0.12 else "right" if frac > 0.88 else "center"
            ax.plot([x], [y], "o", ms=6, color=color, markeredgecolor=t["surface"],
                    markeredgewidth=1.5, zorder=5)
            ax.annotate(text, (x, y), xytext=(0, 8 if above else -8), textcoords="offset points",
                        ha=ha, va="bottom" if above else "top", fontsize=8, color=t["ink2"])

        first_col = p["cols"][0][0]
        series = df[first_col].dropna() if first_col in df else pd.Series(dtype=float)
        if not series.empty and p.get("peak"):
            idx = series.idxmax()
            label_point(df.loc[idx, "timestamp"], series.loc[idx],
                        f"max {series.loc[idx]:.1f}{p['unit']}", t["s1"])
        if not series.empty and p.get("end_label"):
            idx = series.index[-1]
            label_point(df.loc[idx, "timestamp"], series.loc[idx],
                        f"{series.loc[idx]:.0f}{p['unit']}", t["s1"])

        # Legend whenever there is more than one series (or a shading to explain).
        handles, labels = ax.get_legend_handles_labels()
        if len(p["cols"]) > 1:
            ax.legend(frameon=False, fontsize=8, labelcolor=t["ink2"], loc="upper right",
                      ncols=len(handles))
        elif shade_handle is not None and not legend_done:
            ax.legend(handles=[shade_handle], frameon=False, fontsize=8, labelcolor=t["ink2"],
                      loc="upper right")
            legend_done = True

    locator = mdates.AutoDateLocator(minticks=4, maxticks=10)
    axes[-1].xaxis.set_major_locator(locator)
    axes[-1].xaxis.set_major_formatter(mdates.ConciseDateFormatter(locator))

    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=150, facecolor=t["surface"])
    if show:
        plt.show()
    plt.close(fig)
    return out


# -------------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser(description="Numbers and graphs from the monitor logs.")
    ap.add_argument("--log-dir", type=Path,
                    default=Path(os.environ.get("SCS_LOG_DIR", ROOT / "logs")),
                    help="folder containing battery/ cpu/ memory/ disk/ (default: ./logs)")
    ap.add_argument("--days", type=float, default=1.0, help="how many days back (default 1)")
    ap.add_argument("--all", action="store_true", help="use every log, ignore --days")
    ap.add_argument("--out", type=Path, help="PNG path (default: reports/report_<time>.png)")
    ap.add_argument("--show", action="store_true", help="also open the graph in a window")
    ap.add_argument("--no-plot", action="store_true", help="print numbers only")
    ap.add_argument("--theme", choices=THEMES, default="light")
    args = ap.parse_args()

    since = None if args.all else pd.Timestamp.now() - pd.Timedelta(days=args.days)
    data = {m: load(m, args.log_dir, since) for m in ("battery", "cpu", "memory", "disk")}

    if all(df.empty for df in data.values()):
        where = "everything" if args.all else f"the last {args.days:g} day(s)"
        print(f"No log data for {where} in {args.log_dir}.")
        print("Start the monitors with ./startup.sh, let them run a while, and try again.")
        return 1

    report_battery(data["battery"])
    report_cpu(data["cpu"])
    report_memory(data["memory"])
    report_disk(data["disk"])

    if not args.no_plot:
        out = args.out or ROOT / "reports" / f"report_{datetime.now():%Y%m%d_%H%M}.png"
        try:
            saved = make_graph(data, args.theme, out, args.show)
        except ImportError:
            print("\nmatplotlib is not installed, so no graph was drawn.")
            print("Run: pip install -r analyze/requirements.txt")
            return 0
        if saved:
            print(f"\nGraph saved to {saved}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
