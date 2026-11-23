#!/usr/bin/env bash
########################################################################
# startup.sh - start, stop and inspect every monitor at once
# Part of systemcheckscripts. Run `./startup.sh help` for usage.
########################################################################

set -u

SCS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORS=(battery cpu memory disk)

usage() {
	cat <<'EOF'
startup.sh - control all the monitors at once

Usage: ./startup.sh [command] [options]

Commands
  start [--interval N] [--for D]   start every monitor in the background
                                   (options are passed to each monitor;
                                    omit --interval to use each monitor's
                                    own default)
  stop                             stop every monitor
  restart [options]                stop, then start
  status                           show which monitors are running
  once                             take one reading from every monitor
  summary                          quick numbers from today's logs
  report [options]                 graphs + numbers over time (python,
                                   see analyze/report.py --help)
  help                             this message

With no command, 'start' is assumed.

Examples
  ./startup.sh                     start everything
  ./startup.sh start --for 2h      log everything for 2 hours, then stop
  ./startup.sh report --days 7     report for the last week
EOF
}

# run_all <command> [args...] - run a command on every monitor.
# Sets RUN_OK / RUN_FAIL to the number of monitors that succeeded / failed.
run_all() {
	local cmd="$1" m
	shift
	RUN_OK=0
	RUN_FAIL=0
	for m in "${MONITORS[@]}"; do
		if "${SCS_ROOT}/${m}.sh" "${cmd}" "$@"; then
			RUN_OK=$((RUN_OK + 1))
		else
			RUN_FAIL=$((RUN_FAIL + 1))
		fi
	done
}

cmd="${1:-start}"
[[ $# -gt 0 ]] && shift

case "${cmd}" in
	help | -h | --help)
		usage
		;;
	start)
		run_all start "$@"
		((RUN_OK > 0)) || exit 1
		;;
	stop)
		run_all stop
		;;
	restart)
		run_all stop
		run_all start "$@"
		((RUN_OK > 0)) || exit 1
		;;
	status)
		run_all status
		;;
	once)
		for m in "${MONITORS[@]}"; do
			printf '\n== %s ==\n' "${m}"
			"${SCS_ROOT}/${m}.sh" once
		done
		;;
	summary)
		for m in "${MONITORS[@]}"; do
			printf '\n== %s ==\n' "${m}"
			"${SCS_ROOT}/${m}.sh" summary
		done
		;;
	report)
		py="python3"
		[[ -x "${SCS_ROOT}/venv/bin/python" ]] && py="${SCS_ROOT}/venv/bin/python"
		exec "${py}" "${SCS_ROOT}/analyze/report.py" "$@"
		;;
	*)
		printf 'Unknown command: %s\n\n' "${cmd}" >&2
		usage >&2
		exit 1
		;;
esac
