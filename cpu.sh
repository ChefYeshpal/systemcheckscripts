#!/usr/bin/env bash
########################################################################
# cpu.sh - CPU temperature, usage, frequency, load and fan speed
# Part of systemcheckscripts. Run `./cpu.sh help` for usage.
#
# Reads /sys and /proc only. Fields a machine doesn't expose (for example
# fan speed) are left blank in the CSV.
########################################################################

# shellcheck disable=SC2034  # variables below are used by lib/common.sh
set -u

SCS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON_SCRIPT="${SCS_ROOT}/cpu.sh"
# shellcheck source=lib/common.sh
source "${SCS_ROOT}/lib/common.sh"

MON_NAME="cpu"
MON_DESC="CPU temperature, usage, frequency, load and fan speed"
MON_INTERVAL=30
MON_HEADER="temp_c,usage_pct,freq_mhz,load1,fan_rpm"
MON_NEEDS_BASELINE=1

HWMON_DIR="${SCS_HWMON_DIR:-/sys/class/hwmon}"
THERMAL_DIR="${SCS_THERMAL_DIR:-/sys/class/thermal}"
CPU_DIR="${SCS_CPU_DIR:-/sys/devices/system/cpu}"

TEMP_FILE=""
FAN_FILE=""
FREQ_FILES=()
PREV_TOTAL=0
PREV_IDLE=0
CUR_TOTAL=0
CUR_IDLE=0

# Sets CUR_TOTAL / CUR_IDLE from the aggregate line of /proc/stat.
_cpu_times() {
	local skip user nice system idle iowait irq softirq steal rest
	read -r skip user nice system idle iowait irq softirq steal rest </proc/stat
	CUR_IDLE=$((idle + iowait))
	CUR_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
}

mon_init() {
	local d="" n="" f=""
	TEMP_FILE=""
	FAN_FILE=""
	FREQ_FILES=()

	for d in "${HWMON_DIR}"/hwmon*; do
		[[ -d "${d}" ]] || continue
		sys_read "${d}/name" n
		case "${n}" in
			coretemp | k10temp | zenpower | cpu_thermal | cpu-thermal)
				[[ -z "${TEMP_FILE}" && -r "${d}/temp1_input" ]] && TEMP_FILE="${d}/temp1_input"
				;;
		esac
		[[ -z "${FAN_FILE}" && -r "${d}/fan1_input" ]] && FAN_FILE="${d}/fan1_input"
	done

	# Fallback: thermal zones.
	if [[ -z "${TEMP_FILE}" ]]; then
		for d in "${THERMAL_DIR}"/thermal_zone*; do
			[[ -d "${d}" ]] || continue
			sys_read "${d}/type" n
			if [[ "${n}" == "x86_pkg_temp" || "${n}" == "acpitz" ]] && [[ -r "${d}/temp" ]]; then
				TEMP_FILE="${d}/temp"
				break
			fi
		done
	fi

	for f in "${CPU_DIR}"/cpu[0-9]*/cpufreq/scaling_cur_freq; do
		[[ -r "${f}" ]] && FREQ_FILES+=("${f}")
	done

	_cpu_times
	PREV_TOTAL=${CUR_TOTAL}
	PREV_IDLE=${CUR_IDLE}
	return 0
}

mon_sample() {
	local t="" temp_c="" usage="" freq="" load1="" fan="" f="" khz="" skip=""
	local sum=0 n=0 dt=0 di=0

	if [[ -n "${TEMP_FILE}" ]]; then
		sys_read "${TEMP_FILE}" t
		[[ -n "${t}" ]] && fixed_point "${t}" 3 1 temp_c
	fi

	# Usage since the previous *measured* sample. Skip if too little time
	# has passed to be meaningful (e.g. the very first sample).
	_cpu_times
	dt=$((CUR_TOTAL - PREV_TOTAL))
	di=$((CUR_IDLE - PREV_IDLE))
	if ((dt >= 50)); then
		fixed_point $(((dt - di) * 1000 / dt)) 1 1 usage
		PREV_TOTAL=${CUR_TOTAL}
		PREV_IDLE=${CUR_IDLE}
	fi

	for f in "${FREQ_FILES[@]}"; do
		sys_read "${f}" khz
		if [[ -n "${khz}" ]]; then
			sum=$((sum + khz))
			n=$((n + 1))
		fi
	done
	((n > 0)) && freq=$((sum / n / 1000))

	read -r load1 skip </proc/loadavg
	[[ -n "${FAN_FILE}" ]] && sys_read "${FAN_FILE}" fan

	SAMPLE_ROW="${temp_c},${usage},${freq},${load1},${fan}"
}

mon_summary() {
	csv_stats "$1" 2 "CPU temperature" "°C"
	csv_stats "$1" 3 "CPU usage" "%"
	csv_stats "$1" 4 "CPU frequency" " MHz"
	csv_stats "$1" 5 "Load (1 min)" ""
	csv_stats "$1" 6 "Fan speed" " RPM"
}

monitor_main "$@"
