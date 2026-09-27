# shellcheck shell=bash
# Shared helpers for the hpc-jobs scripts. Source it: . "$(dirname "$0")/lib.sh"
HPC_JOBS_ROOT="${HPC_JOBS_ROOT:-/data/jobs}"
HPC_REFS_ROOT="${HPC_REFS_ROOT:-/data/refs}"
HPC_IMAGES_ROOT="${HPC_IMAGES_ROOT:-/data/images}"
HPC_JOBCOMP_LOG="${HPC_JOBCOMP_LOG:-/var/log/slurm/jobcomp.log}"

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

iso_in() { date -u -d "@$(( $(date -u +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

# Value of KEY in a line of space-separated KEY=value pairs.
field() { sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"$2"; }

# One line per job: active jobs from squeue, finished jobs from the job
# completion log (JobCompType=jobcomp/filetxt), otherwise UNKNOWN. A requeued
# job has one log record per run; the last one is its current state.
job_line() {
  local id="$1" line
  line=$(squeue -h -j "$id" -o '%i %T elapsed=%M gres=%b reason=%R' 2>/dev/null || true)
  if [[ -n "$line" ]]; then printf '%s\n' "$line"; return 0; fi
  line=$(grep "^JobId=$id " "$HPC_JOBCOMP_LOG" 2>/dev/null | tail -n1 || true)
  if [[ -n "$line" ]]; then
    printf '%s %s exit=%s start=%s end=%s tres=%s\n' "$id" "$(field JobState "$line")" \
      "$(field ExitCode "$line")" "$(field StartTime "$line")" "$(field EndTime "$line")" "$(field Tres "$line")"
    return 0
  fi
  printf '%s UNKNOWN not in squeue or %s\n' "$id" "$HPC_JOBCOMP_LOG"
}

# The token reaches curl through a pipe (printf is a builtin), never argv,
# so other users on the box cannot read it from the process list.
api_request() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsS -X "$method")
  [[ -n "${PAPERCLIP_RUN_ID:-}" ]] && args+=(-H "X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  curl "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$PAPERCLIP_API_KEY") "$PAPERCLIP_API_URL$path"
}

# Sets the issue monitor so Paperclip wakes this agent to check its jobs.
# PATCH replaces the whole executionPolicy, so merge into the current one.
# A fired monitor leaves the policy, and its deadline stays only in
# executionState; carry the later of that deadline and the new one.
schedule_monitor() {
  local minutes="$1" notes="$2" timeout_seconds="${3:-}" issue monitor body
  if [[ -z "${PAPERCLIP_API_URL:-}" || -z "${PAPERCLIP_API_KEY:-}" || -z "${PAPERCLIP_TASK_ID:-}" ]]; then
    printf 'monitor: not scheduled (needs PAPERCLIP_API_URL, PAPERCLIP_API_KEY and PAPERCLIP_TASK_ID)\n'
    return 0
  fi
  issue=$(api_request GET "/api/issues/$PAPERCLIP_TASK_ID") || die "could not read issue $PAPERCLIP_TASK_ID"
  monitor=$(jq -nc --arg next "$(iso_in $(( minutes * 60 )))" --arg notes "${notes:0:500}" \
    --arg timeout "$( [[ -n "$timeout_seconds" ]] && iso_in "$timeout_seconds" )" \
    '{nextCheckAt: $next, notes: $notes, kind: "external_service", serviceName: "slurm", recoveryPolicy: "escalate_to_board"}
     + (if $timeout == "" then {} else {timeoutAt: $timeout} end)')
  body=$(jq -c --argjson m "$monitor" '
    (.executionPolicy.monitor.timeoutAt
      // (if .executionState.monitor.status == "triggered" then .executionState.monitor.timeoutAt else null end)) as $old
    | ([$old, $m.timeoutAt] | map(select(. != null)) | max) as $deadline
    | {executionPolicy: ((.executionPolicy // {})
        | .monitor = ((.monitor // {}) + $m + (if $deadline then {timeoutAt: $deadline} else {} end)))}' <<<"$issue")
  api_request PATCH "/api/issues/$PAPERCLIP_TASK_ID" "$body" \
    | jq -r '"monitor: next check " + (.monitorNextCheckAt // "NOT SET")'
}
