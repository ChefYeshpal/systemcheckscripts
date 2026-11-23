#!/usr/bin/env bash
########################################################################
# memory.sh - RAM and swap usage
# Part of systemcheckscripts. Run `./memory.sh help` for usage.
########################################################################

# shellcheck disable=SC2034  # variables below are used by lib/common.sh
set -u

SCS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON_SCRIPT="${SCS_ROOT}/memory.sh"
# shellcheck source=lib/common.sh
source "${SCS_ROOT}/lib/common.sh"

MON_NAME="memory"
MON_DESC="RAM and swap usage"
MON_INTERVAL=60
MON_HEADER="mem_used_pct,mem_used_mb,mem_available_mb,swap_used_mb"

mon_sample() {
	local key="" val="" unit=""
	local mem_total=0 mem_avail=0 swap_total=0 swap_free=0
	local used_pct="" used_mb=0 avail_mb=0 swap_mb=0

	while read -r key val unit; do
		case "${key}" in
			MemTotal:) mem_total=${val} ;;
			MemAvailable:) mem_avail=${val} ;;
			SwapTotal:) swap_total=${val} ;;
			SwapFree:) swap_free=${val} ;;
		esac
	done </proc/meminfo

	if ((mem_total > 0)); then
		fixed_point $(((mem_total - mem_avail) * 1000 / mem_total)) 1 1 used_pct
	fi
	used_mb=$(((mem_total - mem_avail) / 1024))
	avail_mb=$((mem_avail / 1024))
	swap_mb=$(((swap_total - swap_free) / 1024))

	SAMPLE_ROW="${used_pct},${used_mb},${avail_mb},${swap_mb}"
}

mon_summary() {
	csv_stats "$1" 2 "RAM used" "%"
	csv_stats "$1" 3 "RAM used" " MB"
	csv_stats "$1" 4 "RAM available" " MB"
	csv_stats "$1" 5 "Swap used" " MB"
}

monitor_main "$@"
