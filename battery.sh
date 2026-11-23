#!/usr/bin/env bash
########################################################################
# battery.sh - battery charge, power draw, health and AC state
# Part of systemcheckscripts. Run `./battery.sh help` for usage.
# Original script by ChefYeshpal (created 02-07-2026); reworked to use the
# shared monitor framework in lib/common.sh.
#
# Reads /sys/class/power_supply (Linux). Handles laptops with one or
# several batteries, and batteries that report charge_* instead of
# energy_*.
########################################################################

# shellcheck disable=SC2034  # variables below are used by lib/common.sh
set -u

SCS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON_SCRIPT="${SCS_ROOT}/battery.sh"
# shellcheck source=lib/common.sh
source "${SCS_ROOT}/lib/common.sh"

MON_NAME="battery"
MON_DESC="battery charge, power draw, health and AC state"
MON_INTERVAL=60
MON_HEADER="percent,status,power_w,energy_wh,energy_full_wh,health_pct,cycle_count,voltage_v,ac_online"

# Overridable for testing: SCS_POWER_SUPPLY_DIR, and SCS_BATTERY=BAT1 to
# pin one battery instead of using all of them.
PS_DIR="${SCS_POWER_SUPPLY_DIR:-/sys/class/power_supply}"
BAT_DIRS=()
AC_DIR=""

mon_init() {
	local d="" ptype=""
	BAT_DIRS=()
	AC_DIR=""

	if [[ -n "${SCS_BATTERY:-}" ]]; then
		[[ -d "${PS_DIR}/${SCS_BATTERY}" ]] && BAT_DIRS+=("${PS_DIR}/${SCS_BATTERY}")
	else
		for d in "${PS_DIR}"/BAT*; do
			[[ -d "${d}" ]] && BAT_DIRS+=("${d}")
		done
	fi

	if ((${#BAT_DIRS[@]} == 0)); then
		printf 'battery: no battery found in %s (is this a desktop?)\n' "${PS_DIR}" >&2
		return 1
	fi

	for d in "${PS_DIR}"/*; do
		sys_read "${d}/type" ptype
		if [[ "${ptype}" == "Mains" ]]; then
			AC_DIR="${d}"
			break
		fi
	done
	return 0
}

# _bat_energy <dir> <now|full|full_design> <outvar>
# Sets outvar to micro-watt-hours, converting from charge_* (uAh) when the
# battery doesn't report energy_*. Empty if unavailable.
_bat_energy() {
	local dir="$1" what="$2" out="$3" v="" c="" volt=""
	sys_read "${dir}/energy_${what}" v
	if [[ -z "${v}" ]]; then
		sys_read "${dir}/charge_${what}" c
		if [[ -n "${c}" ]]; then
			if [[ "${what}" == "full_design" ]]; then
				sys_read "${dir}/voltage_min_design" volt
			fi
			[[ -z "${volt}" ]] && sys_read "${dir}/voltage_now" volt
			[[ -n "${volt}" ]] && v=$((c * volt / 1000000))
		fi
	fi
	printf -v "${out}" '%s' "${v}"
}

mon_sample() {
	local b="" st="" pw="" cur="" volt="" cycles="" volt_first="" first_status=""
	local e_now="" e_full="" e_design=""
	local sum_now=0 sum_full=0 sum_design=0 sum_pw=0
	local have_energy=0 have_pw=0 any_dis=0 any_chg=0
	local status="" percent="" ac="" power_w="" wh="" full_wh="" health="" volt_v=""

	for b in "${BAT_DIRS[@]}"; do
		_bat_energy "${b}" now e_now
		_bat_energy "${b}" full e_full
		_bat_energy "${b}" full_design e_design
		if [[ -n "${e_now}" && -n "${e_full}" ]]; then
			have_energy=1
			sum_now=$((sum_now + e_now))
			sum_full=$((sum_full + e_full))
			[[ -n "${e_design}" ]] && sum_design=$((sum_design + e_design))
		fi

		# Power: power_now (uW), or current_now (uA) x voltage_now (uV).
		sys_read "${b}/power_now" pw
		if [[ -z "${pw}" ]]; then
			sys_read "${b}/current_now" cur
			sys_read "${b}/voltage_now" volt
			[[ -n "${cur}" && -n "${volt}" ]] && pw=$((cur * volt / 1000000))
		fi
		if [[ -n "${pw}" ]]; then
			((pw < 0)) && pw=$((-pw))
			sum_pw=$((sum_pw + pw))
			have_pw=1
		fi

		sys_read "${b}/status" st
		[[ -z "${first_status}" ]] && first_status="${st}"
		[[ "${st}" == "Discharging" ]] && any_dis=1
		[[ "${st}" == "Charging" ]] && any_chg=1
		[[ -z "${volt_first}" ]] && sys_read "${b}/voltage_now" volt_first
		[[ -z "${cycles}" ]] && sys_read "${b}/cycle_count" cycles
	done

	if ((any_dis)); then
		status="Discharging"
	elif ((any_chg)); then
		status="Charging"
	else
		status="${first_status}"
	fi

	# Percentage: trust the firmware value for a single battery,
	# otherwise compute it across all batteries.
	if ((${#BAT_DIRS[@]} == 1)); then
		sys_read "${BAT_DIRS[0]}/capacity" percent
	fi
	if [[ -z "${percent}" ]] && ((have_energy && sum_full > 0)); then
		percent=$((sum_now * 100 / sum_full))
	fi

	((have_pw)) && fixed_point "${sum_pw}" 6 2 power_w
	if ((have_energy)); then
		fixed_point "${sum_now}" 6 2 wh
		fixed_point "${sum_full}" 6 2 full_wh
		((sum_design > 0)) && fixed_point $((sum_full * 1000 / sum_design)) 1 1 health
	fi
	[[ -n "${volt_first}" ]] && fixed_point "${volt_first}" 6 2 volt_v
	[[ -n "${AC_DIR}" ]] && sys_read "${AC_DIR}/online" ac

	SAMPLE_ROW="${percent},${status},${power_w},${wh},${full_wh},${health},${cycles},${volt_v},${ac}"
}

mon_summary() {
	awk -F, '
		function hm(s) { return sprintf("%dh %02dm", int(s / 3600), int((s % 3600) / 60)) }
		NR == 1 { next }
		{
			t = substr($1, 12, 2) * 3600 + substr($1, 15, 2) * 60 + substr($1, 18, 2)
			n++
			if (n == 1) first = substr($1, 12, 8)
			last = substr($1, 12, 8)
			if ($2 != "") pct = $2
			if ($7 != "") health = $7
			if ($8 != "") cycles = $8
			status = $3
			if (n > 1) {
				dt = t - tprev
				if (dt > 0 && dt <= 1800) {
					if (pstat == "Discharging") {
						dis += dt
						if (ppct != "" && $2 != "") drop += ppct - $2
						if (pw != "") { wsum += pw * dt; wdt += dt }
					} else if (pstat == "Charging") {
						chg += dt
					}
				}
			}
			tprev = t; pstat = $3; ppct = $2; pw = $4
		}
		END {
			if (n == 0) { print "No samples yet."; exit }
			printf "Samples:           %d (%s to %s)\n", n, first, last
			printf "Charge now:        %s%% (%s)\n", pct, status
			if (health != "") printf "Battery health:    %s%% of design capacity\n", health
			if (cycles != "") printf "Charge cycles:     %s\n", cycles
			printf "On battery:        %s\n", hm(dis)
			printf "Charging:          %s\n", hm(chg)
			if (dis >= 600 && drop > 0) {
				rate = drop / (dis / 3600)
				printf "Drain rate:        %.1f %%/hour\n", rate
				if (wdt > 0) printf "Avg power draw:    %.1f W (on battery)\n", wsum / wdt
				printf "Full-charge life:  ~%.1f h at this rate\n", 100 / rate
				printf "Remaining:         ~%.1f h from %s%%\n", pct / rate, pct
			} else {
				print "Drain rate:        not enough discharge data yet (needs 10+ min on battery)"
			}
		}
	' "$1"
}

monitor_main "$@"
