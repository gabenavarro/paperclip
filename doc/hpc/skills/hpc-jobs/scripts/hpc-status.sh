#!/usr/bin/env bash
# One line per job. Until every job has a final state, reschedules the issue monitor
# (an unknown state, e.g. while slurmctld restarts, keeps checking until the monitor times out).
# Usage: bash scripts/hpc-status.sh [--next-check MINUTES] JOBID...
set -euo pipefail
. "$(dirname "$0")/lib.sh"

next=30
if [[ "${1:-}" == "--next-check" ]]; then next="$2"; shift 2; fi
[[ $# -gt 0 ]] || die "usage: hpc-status.sh [--next-check MINUTES] JOBID..."
active=0
for id in "$@"; do
  line=$(job_line "$id")
  printf '%s\n' "$line"
  case "$(awk '{print $2}' <<<"$line")" in
    COMPLETED | FAILED | CANCELLED | TIMEOUT | OUT_OF_MEMORY | NODE_FAIL | BOOT_FAIL | DEADLINE | PREEMPTED) ;;
    *) active=1 ;;
  esac
done
if [[ $active -eq 1 ]]; then schedule_monitor "$next" "slurm jobs $*"; fi
