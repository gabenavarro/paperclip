#!/usr/bin/env bash
# Submits one job to Slurm and schedules the issue monitor. With --image the
# command runs in that Apptainer container; without it, on the host from the
# job directory (for a Nextflow head job, which must reach sbatch itself).
# --checkpoint: Slurm sends USR1 to the batch shell 5 minutes before the time
# limit; the shell forwards it to the job, waits for the checkpoint, requeues.
# Usage: bash scripts/hpc-submit.sh --job DIR [--image SIF] [--gpus 1] [--cpus 16] [--mem 64G]
#          [--time MINUTES (default 1440)] [--checkpoint] -- COMMAND...
set -euo pipefail
. "$(dirname "$0")/lib.sh"

job="" image="" gpus=1 cpus=16 mem=64G time=1440 checkpoint=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --job) job="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --checkpoint) checkpoint=1; shift ;;
    --gpus) gpus="$2"; shift 2 ;;
    --cpus) cpus="$2"; shift 2 ;;
    --mem) mem="$2"; shift 2 ;;
    --time) time="$2"; shift 2 ;;
    --) shift; break ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ $# -gt 0 ]] || die "missing command after --"
[[ -n "$job" ]] || die "--job is required"
[[ "$gpus" =~ ^[0-9]+$ && "$cpus" =~ ^[0-9]+$ ]] || die "--gpus and --cpus take whole numbers"
[[ "$time" =~ ^[0-9]+$ ]] || die "--time takes minutes (1440 = 24 h)"
job=$(realpath -m "$job")
[[ "$job" == "$(realpath -m "$HPC_JOBS_ROOT")"/* ]] || die "job directory must be under $HPC_JOBS_ROOT"
[[ -z "$image" || -f "$image" ]] || die "image not found: $image"
mkdir -p "$job/logs" "$job/tmp"

command=("$@")
if [[ -n "$image" ]]; then
  nv=()
  [[ "$gpus" -gt 0 ]] && nv=(--nv)
  # The roots are also bound read-only at their own paths, so absolute links in
  # inputs/ (to refs or to another job's outputs) resolve in the container.
  jobs_root="${HPC_JOBS_ROOT%/}" refs_root="${HPC_REFS_ROOT%/}"
  command=(apptainer exec "${nv[@]}" --containall --workdir "$job/tmp"
    --bind "$job:/work" --bind "$refs_root:/refs:ro"
    --bind "$jobs_root:$jobs_root:ro" --bind "$refs_root:$refs_root:ro" "$image" "$@")
fi
script="$job/logs/submit-$(date -u +%Y%m%dT%H%M%SZ).sbatch"
{
  printf '#!/bin/bash\nset -uo pipefail\ncd %q\n' "$job"
  if [[ $checkpoint -eq 1 ]]; then
    printf 'trap '"'"'kill -USR1 "$child" 2>/dev/null; wait "$child"; scontrol requeue "$SLURM_JOB_ID"'"'"' USR1\n'
    printf '%q ' "${command[@]}"; printf '&\nchild=$!\nwait "$child"\n'
  else
    printf 'exec '; printf '%q ' "${command[@]}"; printf '\n'
  fi
} >"$script"

# --chdir: Slurm otherwise starts the job in the submit directory, the per-run
# workspace, which Paperclip deletes after the run.
args=(--job-name "$(basename "$job")" --chdir "$job" --cpus-per-task "$cpus" --mem "$mem" --time "$time"
  --output "$job/logs/%j.out")
[[ "$gpus" -gt 0 ]] && args+=(--gres "gpu:$gpus")
[[ $checkpoint -eq 1 ]] && args+=(--signal "B:USR1@300" --requeue)

if ! err=$(sbatch --test-only "${args[@]}" "$script" 2>&1 >/dev/null); then
  die "sbatch --test-only rejected the job: $err"
fi
jobid=$(sbatch --parsable "${args[@]}" "$script")
jobid="${jobid%%;*}"
printf 'submitted %s (script: %s, log: %s/logs/%s.out)\n' "$jobid" "$script" "$job" "$jobid"
# A checkpointed job requeues itself, so it has no fixed end: no monitor timeout.
timeout=$(( time * 60 + 1800 ))
[[ $checkpoint -eq 1 ]] && timeout=""
schedule_monitor 15 "slurm job $jobid in $job" "$timeout"
