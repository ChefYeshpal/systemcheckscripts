########################################################################
# Created Date: 02-07-2026
# By: ChefYeshpal
# Last Modified: 02-07-2026
# Last Modified By: ChefYeshpal

# Purpose
# Used to graph battery logs stored locally in test_filefolder/batterytest/
# No data is sent anywhere; everything stays on your system
# This script will create a file with name [Date in UTC of created CSV]_UTC_[Date and time in UTC of png created]_UTC_graph.png in the test_filefolder/batterytest/ directory



from __future__ import annotations

USAGE_TEXT = """\

## No data is sent to any server, all data is stored locally on YOUR system. ##

This script scans the local test_filefolder/batterytest directory for CSV logs,
lists them newest-first, and plots the file you choose.

You will need to install these packages: (prefrably via pip)
1. matplotlib

To use this script, and it would be preferred to use a virtual environment.

If no interactive matplotlib backend is available, the graph is saved as a PNG
next to the CSV file and the script will try to open it automatically.

To run a command, you can use the arguments: ./batterygraph.py [variable]

##### VARIABLES #####
1. help: prints a help message
2. list: lists the available csv files without plotting
3. plot [file number or path]: lists the files and plots the selected csv file directly

If no argument is provided, the script will list the CSV files and ask you
which one to plot.
"""

import csv
import re
import sys
import subprocess
import shutil
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

try:
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
except ImportError:  # pragma: no cover - handled at runtime
    plt = None
    mdates = None


BASE_DIR = Path(__file__).resolve().parent
LOG_DIR = BASE_DIR / "test_filefolder" / "batterytest"
TIMESTAMP_RE = re.compile(r"^(?P<date>\d{8})(?:[T_\- ]?(?P<time>\d{6}))?")


@dataclass(frozen=True)
class LogFile:
    path: Path
    timestamp: datetime


def print_usage() -> None:
    print(USAGE_TEXT.rstrip())


def parse_filename_timestamp(path: Path) -> datetime:
    match = TIMESTAMP_RE.match(path.stem)
    if match:
        date_part = match.group("date")
        time_part = match.group("time") or "000000"
        return datetime.strptime(date_part + time_part, "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)

    return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)


def discover_csv_files(log_dir: Path) -> list[LogFile]:
    if not log_dir.exists():
        return []

    entries: list[LogFile] = []
    for path in log_dir.glob("*.csv"):
        if path.is_file():
            entries.append(LogFile(path=path, timestamp=parse_filename_timestamp(path)))

    entries.sort(key=lambda entry: (entry.timestamp, entry.path.name), reverse=True)
    return entries


def format_display_timestamp(timestamp: datetime) -> str:
    return timestamp.astimezone(timezone.utc).strftime("%d %b %Y, %H:%M:%S")


def list_csv_files(entries: list[LogFile]) -> None:
    if not entries:
        print(f"No CSV files found in {LOG_DIR}")
        return

    print("Available CSV files:")
    for index, entry in enumerate(entries, start=1):
        print(f"{index}. {entry.path.name} - {format_display_timestamp(entry.timestamp)}")


def choose_entry(entries: list[LogFile]) -> LogFile:
    while True:
        prompt = f"Select a file to plot [1-{len(entries)}] (default 1): "
        choice = input(prompt).strip()

        if not choice:
            return entries[0]

        if choice.isdigit():
            index = int(choice)
            if 1 <= index <= len(entries):
                return entries[index - 1]

        for entry in entries:
            if choice == str(entry.path) or choice == entry.path.name:
                return entry

        print("Invalid selection. Enter a number from the list or a file name.")


def resolve_direct_selection(argument: str, entries: list[LogFile]) -> LogFile:
    if argument.isdigit():
        index = int(argument)
        if 1 <= index <= len(entries):
            return entries[index - 1]

    candidate = Path(argument)
    if not candidate.is_absolute():
        candidate = (LOG_DIR / candidate).resolve()

    for entry in entries:
        if entry.path.resolve() == candidate.resolve() or entry.path.name == argument:
            return entry

    raise ValueError(f"Could not find a matching CSV file for: {argument}")


def read_battery_points(csv_path: Path) -> tuple[list[datetime], list[float]]:
    timestamps: list[datetime] = []
    percentages: list[float] = []

    with csv_path.open(newline="", encoding="utf-8") as csv_file:
        reader = csv.DictReader(csv_file)
        for row in reader:
            raw_timestamp = (row.get("timestamp") or "").strip()
            raw_percentage = (row.get("battery_percentage") or "").strip()

            if not raw_timestamp or not raw_percentage or raw_percentage.lower() == "unknown":
                continue

            try:
                timestamp = datetime.fromisoformat(raw_timestamp)
            except ValueError:
                continue

            try:
                percentage = float(raw_percentage.rstrip("%"))
            except ValueError:
                continue

            timestamps.append(timestamp)
            percentages.append(percentage)

    return timestamps, percentages


def build_output_path(entry: LogFile) -> Path:
    created_timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M_UTC")
    return entry.path.with_name(f"{entry.path.stem}_{created_timestamp}_graph.png")


def plot_csv(entry: LogFile) -> None:
    if plt is None or mdates is None:
        print("matplotlib is not installed. Install it to plot battery graphs.")
        raise SystemExit(1)

    timestamps, percentages = read_battery_points(entry.path)
    if not timestamps:
        raise SystemExit(f"No usable battery data found in {entry.path}")

    figure, axis = plt.subplots(figsize=(12, 6))
    axis.plot(timestamps, percentages, marker="o", linewidth=1.5, markersize=3)
    axis.set_title(f"Battery charge over time - {entry.path.name}")
    axis.set_xlabel("Time")
    axis.set_ylabel("Charge %")
    axis.set_ylim(0, 100)
    axis.grid(True, linestyle="--", alpha=0.35)

    locator = mdates.AutoDateLocator()
    formatter = mdates.ConciseDateFormatter(locator)
    axis.xaxis.set_major_locator(locator)
    axis.xaxis.set_major_formatter(formatter)
    figure.autofmt_xdate()
    figure.tight_layout()

    backend_name = plt.get_backend().lower()
    if "agg" in backend_name:
        output_path = build_output_path(entry)
        figure.savefig(output_path, dpi=150, bbox_inches="tight")
        print(f"Saved plot to {output_path}")

        if shutil.which("xdg-open"):
            try:
                subprocess.Popen(["xdg-open", str(output_path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                pass
    else:
        plt.show()


def main(argv: list[str]) -> int:
    if argv and argv[0] in {"help", "-h", "--help"}:
        print_usage()
        return 0

    entries = discover_csv_files(LOG_DIR)
    if argv[0] == "list":
        list_csv_files(entries)
        return 0

    if not entries:
        print(f"No CSV files found in {LOG_DIR}")
        return 1

    if not argv:
        list_csv_files(entries)
        selected = choose_entry(entries)
    elif argv[0] == "plot":
        list_csv_files(entries)
        if len(argv) < 2:
            selected = choose_entry(entries)
        else:
            selected = resolve_direct_selection(argv[1], entries)
    else:
        selected = resolve_direct_selection(argv[0], entries)

    print(f"Plotting {selected.path.name}")
    plot_csv(selected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))