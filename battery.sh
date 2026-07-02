#!/usr/bin/env bash
########################################################################
# Created Date: 02-07-2026
# By: ChefYeshpal
# Last Modified: 02-07-2026
# Last Modified By: ChefYeshpal

# Purpose
# Used to measure battery life in systems
# Interval's are set for 5 minutes

: << 'USAGE'

## No data is sent to any server, all data is stored locally on YOUR system. ##

I've made a "test_filefolder/batterytest" folder in this directory, and already added some arguments in the .gitignore file to ignore the log files. It would be advised to make that folder in your own directory as well to consolidate all your data.

To run a command, you can use the arguments: ./battery.sh [variable]

Variables
1. help: prints a help message
2. runtime: reports how long the logger has been running
3. showlog: prints the csv file
4. killall: stops the background loggerand removes it's tracking files
5. runfor [duration]: runs for that duration of time (in minutes), then notifies you when the time is up

USAGE


set -u

# setting variables for easier use
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_date_utc="$(date -u +%Y%m%d)"
output_file="${script_dir}/test_filefolder/batterytest/${log_date_utc}_UTC_batterylog.csv"
pid_file="${script_dir}/.battery_logger.pid"
state_file="${script_dir}/.battery_logger.state"

notify_user() {
	local title="$1"
	local message="$2"

	if command -v notify-send >/dev/null 2>&1; then
		notify-send "${title}" "${message}" >/dev/null 2>&1 || true
	fi
}

format_duration() {
	local total_seconds="$1"
	local days hours minutes seconds

	days=$((total_seconds / 86400))
	hours=$(((total_seconds % 86400) / 3600))
	minutes=$(((total_seconds % 3600) / 60))
	seconds=$((total_seconds % 60))

	if (( days > 0 )); then
		printf '%dd %dh %dm %ds' "${days}" "${hours}" "${minutes}" "${seconds}"
	elif (( hours > 0 )); then
		printf '%dh %dm %ds' "${hours}" "${minutes}" "${seconds}"
	elif (( minutes > 0 )); then
		printf '%dm %ds' "${minutes}" "${seconds}"
	else
		printf '%ds' "${seconds}"
	fi
}

parse_duration() {
	local input="$1"
	local value unit

	if [[ "${input}" =~ ^([0-9]+)([smhd]?)$ ]]; then
		value="${BASH_REMATCH[1]}"
		unit="${BASH_REMATCH[2]}"
		case "${unit}" in
			s|"") printf '%s' "${value}" ;;
			m) printf '%s' $((value * 60)) ;;
			h) printf '%s' $((value * 3600)) ;;
			d) printf '%s' $((value * 86400)) ;;
		esac
		return 0
	fi

	return 1
}

print_usage() {
	awk '
		/^: << '\''USAGE'\''$/ { in_usage=1; next }
		/^USAGE$/ { in_usage=0; next }
		in_usage { print }
	' "${BASH_SOURCE[0]}"
}

is_running() {
	[[ -f "${pid_file}" ]] || return 1

	local pid
	pid="$(cat "${pid_file}" 2>/dev/null || true)"
	[[ -n "${pid}" ]] || return 1
	kill -0 "${pid}" 2>/dev/null
}

stop_logger() {
	local pid

	if ! [[ -f "${pid_file}" ]]; then
		printf 'Battery logger is not running.\n'
		return 1
	fi

	pid="$(cat "${pid_file}" 2>/dev/null || true)"
	if [[ -n "${pid}" ]]; then
		kill "${pid}" 2>/dev/null || true
		for _ in 1 2 3 4 5; do
			if kill -0 "${pid}" 2>/dev/null; then
				sleep 1
			else
				break
			fi
		done
		kill -9 "${pid}" 2>/dev/null || true
	fi

	rm -f "${pid_file}" "${state_file}"
	printf 'Battery recording stopped.\n'
	notify_user 'Battery recording stopped' "Battery logging has been stopped."
}

show_runtime() {
	local start_epoch now elapsed

	if ! is_running; then
		printf 'Battery logger is not running.\n'
		return 1
	fi

	start_epoch="$(awk -F= '$1 == "start_epoch" {print $2; exit}' "${state_file}" 2>/dev/null || true)"
	if [[ -z "${start_epoch}" ]]; then
		printf 'Battery logger is not running.\n'
		return 1
	fi

	now="$(date +%s)"
	elapsed=$((now - start_epoch))
	if (( elapsed < 0 )); then
		elapsed=0
	fi

	printf 'Battery logger has been running for %s.\n' "$(format_duration "${elapsed}")"
}

start_logger() {
	local duration_seconds="${1:-0}"

	if is_running; then
		printf 'Battery logger is already running.\n'
		return 0
	fi

	nohup bash "${BASH_SOURCE[0]}" --foreground "${duration_seconds}" >/dev/null 2>&1 &
	printf '%s\n' "$!" > "${pid_file}"
	printf 'start_epoch=%s\n' "$(date +%s)" > "${state_file}"
	if (( duration_seconds > 0 )); then
		printf 'duration_seconds=%s\n' "${duration_seconds}" >> "${state_file}"
	fi
	printf 'Battery recording started. Saving to %s\n' "${output_file}"
	notify_user 'Battery recording started' "Saving to ${output_file}"
}

if [[ "${1:-}" == "help" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	print_usage
	exit 0
elif [[ "${1:-}" == "runtime" ]]; then
	show_runtime
	exit $?
elif [[ "${1:-}" == "showlog" ]]; then
	if [[ -f "${output_file}" ]]; then
		cat "${output_file}"
	else
		printf 'No log file found at %s\n' "${output_file}"
	fi
	exit 0
elif [[ "${1:-}" == "killall" ]]; then
	stop_logger
	exit $?
elif [[ "${1:-}" == "runfor" ]]; then
	if [[ -z "${2:-}" ]]; then
		printf 'Usage: %s runfor <duration>\n' "$(basename "${BASH_SOURCE[0]}")"
		exit 1
	fi

	if ! duration_seconds="$(parse_duration "${2}")"; then
		printf 'Invalid duration: %s\n' "${2}"
		exit 1
	fi

	start_logger "${duration_seconds}"
	exit 0
elif [[ "${1:-}" == "--foreground" ]]; then
	shift
else
	start_logger 0
	exit 0
fi

battery_base=""
duration_seconds="${1:-0}"
start_epoch="$(date +%s)"

for candidate in /sys/class/power_supply/BAT*; do
	if [[ -d "${candidate}" ]]; then
		battery_base="${candidate}"
		break
	fi
done

capacity_file="${battery_base}/capacity"
status_file="${battery_base}/status"

if [[ ! -f "${output_file}" ]]; then
	printf 'timestamp,battery_percentage,status\n' > "${output_file}"
fi

trap 'rm -f "${pid_file}" "${state_file}"' EXIT INT TERM

printf 'start_epoch=%s\n' "${start_epoch}" > "${state_file}"

while true; do
	timestamp="$(date --iso-8601=seconds)"

	battery_percentage="unknown"
	if [[ -n "${battery_base}" && -r "${capacity_file}" ]]; then
		battery_percentage="$(cat "${capacity_file}")"
	elif command -v upower >/dev/null 2>&1; then
		battery_device="$(upower -e 2>/dev/null | grep -m 1 'battery' || true)"
		if [[ -n "${battery_device}" ]]; then
			battery_percentage="$(upower -i "${battery_device}" 2>/dev/null | awk -F': *' '/percentage/ {gsub("%", "", $2); print $2; exit}')"
		fi
	fi

	status="unknown"
	if [[ -n "${battery_base}" && -r "${status_file}" ]]; then
		status="$(cat "${status_file}")"
	fi

	printf '%s,%s,%s\n' "${timestamp}" "${battery_percentage}" "${status}" >> "${output_file}"

	if (( duration_seconds > 0 )); then
		now_epoch="$(date +%s)"
		if (( now_epoch - start_epoch >= duration_seconds )); then
			notify_user 'Battery recording finished' "Time elapsed. Log saved to ${output_file}"
			printf 'Battery recording finished. Log saved to %s\n' "${output_file}"
			break
		fi

		remaining_seconds=$((duration_seconds - (now_epoch - start_epoch)))
		if (( remaining_seconds < 300 )); then
			sleep_seconds=${remaining_seconds}
		else
			sleep_seconds=300
		fi
	else
		sleep_seconds=300
	fi

	sleep "${sleep_seconds}"
done
