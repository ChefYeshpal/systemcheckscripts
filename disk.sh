#!/usr/bin/env bash
########################################################################
# disk.sh - disk space used/free and disk read/write throughput
# Part of systemcheckscripts. Run `./disk.sh help` for usage.
#
# Space is measured for one path (default "/", override with
# SCS_DISK_PATH=/home). Throughput is summed over whole physical disks
# (sdX, nvmeXnY, mmcblkX, vdX).
########################################################################

# shellcheck disable=SC2034  # variables below are used by lib/common.sh
set -u

SCS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON_SCRIPT="${SCS_ROOT}/disk.sh"
# shellcheck source=lib/common.sh
source "${SCS_ROOT}/lib/common.sh"

MON_NAME="disk"
MON_DESC="disk space used/free and disk read/write throughput"
MON_INTERVAL=300
MON_HEADER="used_pct,used_gb,avail_gb,read_kbps,write_kbps"
MON_NEEDS_BASELINE=1

DISK_PATH="${SCS_DISK_PATH:-/}"
PREV_T=""
PREV_RD=0
PREV_WR=0
CUR_RD=0
CUR_WR=0

# Sets CUR_RD / CUR_WR to total 512-byte sectors read / written.
_disk_sectors() {
	local maj="" min="" name="" f4="" f5="" f6="" f7="" f8="" f9="" f10="" rest=""
	local re='^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$'
	CUR_RD=0
	CUR_WR=0
	[[ -r /proc/diskstats ]] || return 1
	while read -r maj min name f4 f5 f6 f7 f8 f9 f10 rest; do
		if [[ "${name}" =~ ${re} ]]; then
			CUR_RD=$((CUR_RD + f6))
			CUR_WR=$((CUR_WR + f10))
		fi
	done </proc/diskstats
}

mon_init() {
	PREV_T=""
	if _disk_sectors; then
		printf -v PREV_T '%(%s)T' -1
		PREV_RD=${CUR_RD}
		PREV_WR=${CUR_WR}
	fi
	return 0
}

mon_sample() {
	local -a lines=()
	local fs="" blocks="" used="" avail="" pct="" mnt=""
	local used_pct="" used_gb="" avail_gb="" rd_kbps="" wr_kbps="" t=0 dt=0

	mapfile -t lines < <(df -Pk "${DISK_PATH}" 2>/dev/null)
	if ((${#lines[@]} >= 2)); then
		read -r fs blocks used avail pct mnt <<<"${lines[1]}"
		used_pct="${pct%\%}"
		fixed_point $((used * 100 / 1048576)) 2 2 used_gb
		fixed_point $((avail * 100 / 1048576)) 2 2 avail_gb
	fi

	# Throughput in KB/s since the previous sample.
	printf -v t '%(%s)T' -1
	if _disk_sectors; then
		if [[ -n "${PREV_T}" ]]; then
			dt=$((t - PREV_T))
			if ((dt > 0)); then
				if ((CUR_RD >= PREV_RD && CUR_WR >= PREV_WR)); then
					rd_kbps=$(((CUR_RD - PREV_RD) / 2 / dt))
					wr_kbps=$(((CUR_WR - PREV_WR) / 2 / dt))
				fi
				PREV_T=${t}
				PREV_RD=${CUR_RD}
				PREV_WR=${CUR_WR}
			fi
		else
			PREV_T=${t}
			PREV_RD=${CUR_RD}
			PREV_WR=${CUR_WR}
		fi
	fi

	SAMPLE_ROW="${used_pct},${used_gb},${avail_gb},${rd_kbps},${wr_kbps}"
}

mon_summary() {
	csv_stats "$1" 2 "Disk used" "%"
	csv_stats "$1" 4 "Free space" " GB"
	csv_stats "$1" 5 "Disk read" " KB/s"
	csv_stats "$1" 6 "Disk write" " KB/s"
}

monitor_main "$@"
