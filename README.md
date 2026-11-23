# systemcheckscripts

Small scripts that watch how a Linux laptop/desktop behaves over time: battery life, power draw, CPU temperature and load, memory, disk. Monitoring is plain bash (reads `/proc` and `/sys`, almost no CPU or memory use); analysis and graphs are a separate Python script you run when you want to look at the data.

No data is sent anywhere. Everything is stored locally as CSV files.

## Layout

```
systemcheckscripts/
├── startup.sh          start/stop/status for all monitors at once
├── battery.sh          battery %, power draw (W), health, cycles, AC state
├── cpu.sh              CPU temperature, usage, frequency, load, fan speed
├── memory.sh           RAM and swap usage
├── disk.sh             disk space and read/write throughput
├── lib/common.sh       shared code (the start/stop/log machinery)
├── analyze/
│   ├── report.py       numbers + graphs from the logs
│   └── requirements.txt
├── logs/               CSV logs, one folder per monitor (git-ignored)
└── reports/            generated graphs (git-ignored)
```

## Quick start

```bash
./startup.sh                  # start every monitor in the background
./startup.sh status           # see what's running
./startup.sh summary          # quick numbers from today's logs
./startup.sh report           # graph + numbers (needs python, see below)
./startup.sh stop             # stop everything
```

Log for a fixed amount of time (a bare number means minutes):

```bash
./startup.sh start --for 2h
./battery.sh runfor 30        # just the battery, for 30 minutes
```

Every monitor can also be used on its own: `./battery.sh help`.

| Command | What it does |
| --- | --- |
| `start [--interval N] [--for D]` | start logging in the background |
| `runfor D` | same as `start --for D` |
| `stop` | stop the background logger |
| `status` / `runtime` | is it running, and for how long |
| `once` | take one reading and print it, without logging |
| `showlog` | print today's CSV |
| `summary` | quick numbers from today's CSV |

Intervals take seconds or a suffix: `--interval 30`, `--interval 5m`. Defaults: battery 60s, cpu 30s, memory 60s, disk 300s.

## What gets recorded

Each monitor writes `logs/<name>/YYYYMMDD_<name>.csv` (one file per local day, so a run that crosses midnight just continues in the next file). The first column is always `timestamp`.

| Monitor | Columns |
| --- | --- |
| battery | `percent, status, power_w, energy_wh, energy_full_wh, health_pct, cycle_count, voltage_v, ac_online` |
| cpu | `temp_c, usage_pct, freq_mhz, load1, fan_rpm` |
| memory | `mem_used_pct, mem_used_mb, mem_available_mb, swap_used_mb` |
| disk | `used_pct, used_gb, avail_gb, read_kbps, write_kbps` |

Anything your hardware doesn't report (for example fan speed) is left blank.

## Graphs and numbers (Python)

Python is only used for analysis, never for monitoring.

### How to use venv for python
1. Have python3 installed, and also remember to install python3-venv (on Ubuntu 24.04: `python3.12-venv`)
2. Create your venv "folder" with `python3 -m venv venv`
3. Activate your venv environment with `source venv/bin/activate`
4. Install what the report needs with `pip install -r analyze/requirements.txt`
5. Do your work.
6. To exit the environment, use `deactivate`

Then:

```bash
./startup.sh report                  # last 24 hours
./startup.sh report --days 7         # last week
./startup.sh report --all            # everything in logs/
./startup.sh report --show           # open the graph in a window too
```

(`startup.sh report` uses `venv/bin/python` automatically if it exists. You can also run `python analyze/report.py` directly.)

It prints a summary (battery drain rate in %/hour, average watts, discharge sessions, temperatures, memory, disk) and saves a multi-panel graph to `reports/`.

## Run at login

- GNOME: open **Startup Applications** and add `/full/path/to/systemcheckscripts/startup.sh start`
- or with cron (`crontab -e`): `@reboot /full/path/to/systemcheckscripts/startup.sh start`

## Settings (environment variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `SCS_LOG_DIR` | `./logs` | where the CSVs go |
| `SCS_RUN_DIR` | `./.run` | pid/state files |
| `SCS_BATTERY` | all `BAT*` | pin one battery, e.g. `BAT0` |
| `SCS_DISK_PATH` | `/` | which filesystem `disk.sh` measures |

## Notes

- Linux only (uses `/proc` and `/sys`). Needs bash 4.2+ (any current Ubuntu).
- `notify-send` is optional; if present you get a desktop notification when a timed run finishes.
- Adding a new monitor: copy `memory.sh`, change the name, header and `mon_sample`, and add it to `MONITORS` in `startup.sh`.
