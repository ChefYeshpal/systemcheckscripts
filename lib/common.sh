#!/usr/bin/env bash
########################################################################
# lib/common.sh - shared monitor framework. Source it, don't run it.
#
# A monitor script sets a few variables/functions and then calls
# `monitor_main "$@"`:
#
#   MON_NAME="battery"              # used for log folder + pid file
#   MON_HEADER="a,b,c"              # CSV columns AFTER the timestamp
#   MON_INTERVAL=60                 # default seconds between samples
#   MON_DESC="one line description"
#   mon_init()    { ...; }          # optional; return non-zero (and print
#                                   # a message) if this machine can't be
#                                   # monitored
#   mon_sample()  { SAMPLE_ROW="1,2,3"; }   # must set SAMPLE_ROW
#   mon_summary() { ...; }          # optional; prints a quick summary
#
# Everything the monitors do uses bash builtins and /proc or /sys reads
# wherever possible, so a sample costs almost nothing.
########################################################################

if [[ -z "${SCS_ROOT:-}" ]]; then
	SCS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
SCS_LOG_DIR="${SCS_LOG_DIR:-${SCS_ROOT}/logs}"
SCS_RUN_DIR="${SCS_RUN_DIR:-${SCS_ROOT}/.run}"

# ---------------------------------------------------------------- output

supports_color() {
	[[ -t 1 ]]
}

colorize() {
	local text="$1"
	shift
	if ! supports_color || [[ $# -eq 0 ]]; then
		printf '%s' "${text}"
		return
	fi
	local prefix="" code
	for code in "$@"; do
		prefix+="${code}"
	done
	printf '%b%s%b' "${prefix}" "${text}" '\033[0m'
}

notify_user() {
	local title="$1" message="$2"
	if command -v notify-send >/dev/null 2>&1; then
		notify-send "${title}" "${message}" >/dev/null 2>&1 || true
	fi
}

# ------------------------------------------------------------ durations

format_duration() {
	local total="$1" d h m s
	d=$((total / 86400))
	h=$(((total % 86400) / 3600))
	m=$(((total % 3600) / 60))
	s=$((total % 60))
	if ((d > 0)); then
		printf '%dd %dh %dm %ds' "${d}" "${h}" "${m}" "${s}"
	elif ((h > 0)); then
		printf '%dh %dm %ds' "${h}" "${m}" "${s}"
	elif ((m > 0)); then
		printf '%dm %ds' "${m}" "${s}"
	else
		printf '%ds' "${s}"
	fi
}

# parse_duration <input> <default_unit: s|m|h|d>
# "30" -> default unit, "30s" "30m" "2h" "1d" -> explicit. Prints seconds.
parse_duration() {
	local input="$1" default_unit="${2:-s}" value unit
	if [[ "${input}" =~ ^([0-9]+)([smhd]?)$ ]]; then
		value="${BASH_REMATCH[1]}"
		unit="${BASH_REMATCH[2]:-${default_unit}}"
		case "${unit}" in
			s) printf '%s' "${value}" ;;
			m) printf '%s' $((value * 60)) ;;
			h) printf '%s' $((value * 3600)) ;;
			d) printf '%s' $((value * 86400)) ;;
		esac
		return 0
	fi
	return 1
}

# ---------------------------------------------------------- sysfs helpers

# sys_read <file> <varname>  - read first line of a file into a variable
# without forking. Variable is set to "" if unreadable.
sys_read() {
	local _v=""
	if [[ -r "$1" ]]; then
		read -r _v <"$1" 2>/dev/null || true
	fi
	printf -v "$2" '%s' "${_v}"
}

# fixed_point <integer> <power_of_10> <decimals> <outvar>
# fixed_point 12345678 6 2 v   ->  v=12.34   (no bc / awk / subshell needed)
fixed_point() {
	local n="$1" div=1 scale=1 i scaled
	for ((i = 0; i < $2; i++)); do div=$((div * 10)); done
	for ((i = 0; i < $3; i++)); do scale=$((scale * 10)); done
	scaled=$((n * scale / div))
	printf -v "$4" '%d.%0*d' $((scaled / scale)) "$3" $((scaled % scale))
}

now_epoch() {
	printf '%(%s)T' -1
}

# csv_stats <file> <column#> <label> <unit>  - avg/min/max of one CSV column
csv_stats() {
	awk -F, -v col="$2" -v label="$3" -v unit="$4" '
		NR == 1 { next }
		$col != "" && $col + 0 == $col {
			n++
			s += $col
			if (n == 1 || $col < mn) mn = $col
			if (n == 1 || $col > mx) mx = $col
		}
		END {
			if (n) printf "%-18s avg %.1f%s   min %.1f%s   max %.1f%s\n", label, s / n, unit, mn, unit, mx, unit
			else printf "%-18s no data\n", label
		}
	' "$1"
}

# ------------------------------------------------------------- logging

log_file_for_today() {
	local day
	printf -v day '%(%Y%m%d)T' -1
	printf '%s/%s/%s_%s.csv' "${SCS_LOG_DIR}" "${MON_NAME}" "${day}" "${MON_NAME}"
}

write_sample() {
	local file ts
	file="$(log_file_for_today)"
	if [[ ! -f "${file}" ]]; then
		mkdir -p "$(dirname "${file}")"
		printf 'timestamp,%s\n' "${MON_HEADER}" >"${file}"
	fi
	printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
	printf '%s,%s\n' "${ts}" "${SAMPLE_ROW}" >>"${file}"
}

# ------------------------------------------------------ process control

_pid_file() { printf '%s/%s.pid' "${SCS_RUN_DIR}" "${MON_NAME}"; }
_state_file() { printf '%s/%s.state' "${SCS_RUN_DIR}" "${MON_NAME}"; }

# True if the pid exists and is not a zombie (a finished process that
# nobody has reaped yet still answers `kill -0`).
_pid_alive() {
	local pid="$1" skip="" state=""
	kill -0 "${pid}" 2>/dev/null || return 1
	if [[ -r "/proc/${pid}/stat" ]]; then
		read -r skip skip state _ <"/proc/${pid}/stat"
		[[ "${state}" == "Z" ]] && return 1
	fi
	return 0
}

is_running() {
	local pid
	[[ -f "$(_pid_file)" ]] || return 1
	pid="$(cat "$(_pid_file)" 2>/dev/null || true)"
	[[ -n "${pid}" ]] && _pid_alive "${pid}"
}

stop_monitor() {
	local pid i
	if ! is_running; then
		rm -f "$(_pid_file)" "$(_state_file)"
		printf '[%s] not running.\n' "${MON_NAME}"
		return 1
	fi
	pid="$(cat "$(_pid_file)")"
	kill "${pid}" 2>/dev/null || true
	for i in {1..25}; do
		_pid_alive "${pid}" || break
		sleep 0.2
	done
	kill -9 "${pid}" 2>/dev/null || true
	rm -f "$(_pid_file)" "$(_state_file)"
	printf '[%s] stopped.\n' "${MON_NAME}"
}

show_runtime() {
	local start now
	if ! is_running; then
		printf '[%s] not running.\n' "${MON_NAME}"
		return 1
	fi
	start="$(awk -F= '$1 == "start_epoch" {print $2; exit}' "$(_state_file)" 2>/dev/null || true)"
	now="$(now_epoch)"
	if [[ -z "${start}" ]]; then
		printf '[%s] running (start time unknown).\n' "${MON_NAME}"
		return 0
	fi
	printf '[%s] running for %s (every %ss).\n' "${MON_NAME}" \
		"$(format_duration $((now - start)))" \
		"$(awk -F= '$1 == "interval" {print $2; exit}' "$(_state_file)")"
}

start_monitor() {
	local interval="$1" duration="$2"

	if is_running; then
		printf '[%s] already running.\n' "${MON_NAME}"
		return 0
	fi

	if declare -F mon_init >/dev/null; then
		if ! mon_init; then
			printf '[%s] not started: this machine cannot be monitored.\n' "${MON_NAME}" >&2
			return 1
		fi
	fi

	mkdir -p "${SCS_RUN_DIR}" "${SCS_LOG_DIR}/${MON_NAME}"
	nohup bash "${MON_SCRIPT}" _run "${interval}" "${duration}" >/dev/null 2>&1 &
	printf '%s\n' "$!" >"$(_pid_file)"
	{
		printf 'start_epoch=%s\n' "$(now_epoch)"
		printf 'interval=%s\n' "${interval}"
		printf 'duration=%s\n' "${duration}"
	} >"$(_state_file)"

	printf '[%s] started (every %ss%s). Logging to %s/%s/\n' \
		"${MON_NAME}" "${interval}" \
		"$( ((duration > 0)) && printf ', for %s' "$(format_duration "${duration}")")" \
		"${SCS_LOG_DIR}" "${MON_NAME}"
}

# The actual sampling loop. Runs in the background.
_run_loop() {
	local interval="$1" duration="$2" start sleeper=""
	start="$(now_epoch)"

	if declare -F mon_init >/dev/null; then
		mon_init || exit 1
	fi

	trap 'rm -f "$(_pid_file)" "$(_state_file)"' EXIT
	# `sleep & wait` lets the signal handler fire immediately instead of
	# after the sleep finishes.
	trap '[[ -n "${sleeper}" ]] && kill "${sleeper}" 2>/dev/null; exit 0' TERM INT

	while true; do
		mon_sample
		write_sample

		if ((duration > 0)) && (($(now_epoch) - start >= duration)); then
			notify_user "${MON_NAME} logging finished" "Time is up. Logs are in ${SCS_LOG_DIR}/${MON_NAME}/"
			break
		fi

		sleep "${interval}" &
		sleeper=$!
		wait "${sleeper}" 2>/dev/null || true
	done
}

# ------------------------------------------------------------------ help

print_monitor_help() {
	cat <<EOF
${MON_NAME}.sh - ${MON_DESC}

No data leaves your machine. Logs are CSV files in:
  ${SCS_LOG_DIR}/${MON_NAME}/YYYYMMDD_${MON_NAME}.csv  (one file per day)

Usage: ./${MON_NAME}.sh <command> [options]

Commands
  start [--interval N] [--for D]   start logging in the background
                                   (N: seconds, or 30s/5m/1h; default ${MON_INTERVAL}s)
                                   (D: run for this long then stop; a bare
                                    number means minutes, or use 30m/2h/1d)
  runfor D [--interval N]          same as: start --for D
  stop                             stop the background logger
  status                           is it running?
  runtime                          how long it has been running
  once                             take one sample and print it (no logging)
  showlog                          print today's CSV
  summary                          quick numbers from today's log
  help                             this message

With no command, 'start' is assumed.
EOF
}

# ---------------------------------------------------------------- entry

monitor_main() {
	local cmd="${1:-start}"
	[[ $# -gt 0 ]] && shift

	local interval="${MON_INTERVAL}" duration=0 secs

	case "${cmd}" in
		help | -h | --help)
			print_monitor_help
			return 0
			;;
		stop | killall)
			stop_monitor
			return $?
			;;
		status | runtime)
			show_runtime
			return $?
			;;
		showlog)
			local f
			f="$(log_file_for_today)"
			if [[ -f "${f}" ]]; then
				cat "${f}"
			else
				printf 'No log file yet at %s\n' "${f}"
			fi
			return 0
			;;
		summary)
			if declare -F mon_summary >/dev/null; then
				local f
				f="$(log_file_for_today)"
				if [[ -f "${f}" ]]; then
					mon_summary "${f}"
				else
					printf 'No log file yet at %s\n' "${f}"
				fi
			else
				printf '[%s] has no summary. Use analyze/report.py for numbers and graphs.\n' "${MON_NAME}"
			fi
			return 0
			;;
		once)
			if declare -F mon_init >/dev/null; then
				mon_init || return 1
			fi
			mon_sample
			# Some monitors need two readings to compute a rate.
			if [[ "${MON_NEEDS_BASELINE:-0}" == 1 ]]; then
				sleep 1
				mon_sample
			fi
			printf 'timestamp,%s\n' "${MON_HEADER}"
			local ts
			printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
			printf '%s,%s\n' "${ts}" "${SAMPLE_ROW}"
			return 0
			;;
		_run)
			_run_loop "${1:-${MON_INTERVAL}}" "${2:-0}"
			return $?
			;;
		runfor)
			if [[ -z "${1:-}" ]] || ! duration="$(parse_duration "$1" m)"; then
				printf 'Usage: %s runfor <duration, e.g. 30 or 30m or 2h> [--interval N]\n' "${MON_NAME}.sh" >&2
				return 1
			fi
			shift
			;;
		start) ;;
		*)
			printf 'Unknown command: %s\n\n' "${cmd}" >&2
			print_monitor_help >&2
			return 1
			;;
	esac

	# remaining args: --interval N  /  --for D
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--interval | -i)
				if [[ -z "${2:-}" ]] || ! secs="$(parse_duration "$2" s)" || ((secs < 1)); then
					printf 'Invalid interval: %s\n' "${2:-}" >&2
					return 1
				fi
				interval="${secs}"
				shift 2
				;;
			--for | -f)
				if [[ -z "${2:-}" ]] || ! duration="$(parse_duration "$2" m)"; then
					printf 'Invalid duration: %s\n' "${2:-}" >&2
					return 1
				fi
				shift 2
				;;
			*)
				printf 'Unknown option: %s\n' "$1" >&2
				return 1
				;;
		esac
	done

	start_monitor "${interval}" "${duration}"
}
