#!/usr/bin/env bash

set -u

if [[ "${1:-}" != "--foreground" ]]; then
	nohup bash "${BASH_SOURCE[0]}" --foreground >/dev/null 2>&1 &
	exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_file="${script_dir}/../battery_log.csv"
battery_base=""

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
	sleep 300
done
