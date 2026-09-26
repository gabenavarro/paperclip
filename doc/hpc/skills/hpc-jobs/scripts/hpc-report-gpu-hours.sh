#!/usr/bin/env bash
# Reports a finished job's GPU-hours once, as a Paperclip cost event.
# Cost = GPU-hours x HPC_GPU_HOUR_CENTS; without a rate the event is "unpriced".
# Usage: bash scripts/hpc-report-gpu-hours.sh JOBID JOB_DIR
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[[ $# -eq 2 ]] || die "usage: hpc-report-gpu-hours.sh JOBID JOB_DIR"
id="$1" job="$2" marker="$2/logs/$1.cost-reported"
if [[ -f "$marker" ]]; then printf 'already reported job %s\n' "$id"; exit 0; fi
line=$(grep -m1 "JobId=$id " "$HPC_JOBCOMP_LOG" 2>/dev/null) || die "job $id is not in $HPC_JOBCOMP_LOG yet (still running?)"
gpus=$(sed -n 's/.*gres\/gpu=\([0-9]*\).*/\1/p' <<<"$(field Tres "$line")")
if [[ -z "$gpus" || "$gpus" -eq 0 ]]; then
  mkdir -p "$(dirname "$marker")"; touch "$marker"
  printf 'job %s used no GPUs; nothing to report\n' "$id"; exit 0
fi
start=$(date -d "$(field StartTime "$line")" +%s)
end=$(date -d "$(field EndTime "$line")" +%s)
gpu_seconds=$(( gpus * (end - start) ))
hours=$(awk -v s="$gpu_seconds" 'BEGIN { printf "%.2f", s / 3600 }')
if [[ -n "${HPC_GPU_HOUR_CENTS:-}" ]]; then
  cents=$(awk -v s="$gpu_seconds" -v r="$HPC_GPU_HOUR_CENTS" 'BEGIN { c = s / 3600 * r; printf "%d", (c == int(c)) ? c : int(c) + 1 }')
  status=reported
else
  cents=0; status=unpriced
fi
body=$(jq -nc --arg agent "$PAPERCLIP_AGENT_ID" --arg issue "$PAPERCLIP_TASK_ID" \
  --arg at "$(date -u -d "@$end" +%Y-%m-%dT%H:%M:%SZ)" --argjson cents "$cents" --arg status "$status" \
  '{agentId: $agent, issueId: $issue, provider: "hpc", biller: "hpc", billingType: "fixed", costStatus: $status,
    model: "slurm-gpu-hour", costCents: $cents, occurredAt: $at}')
api_request POST "/api/companies/$PAPERCLIP_COMPANY_ID/cost-events" "$body" >/dev/null
mkdir -p "$(dirname "$marker")"; touch "$marker"
printf 'reported %s GPU-hours (%s cents) for job %s\n' "$hours" "$cents" "$id"
