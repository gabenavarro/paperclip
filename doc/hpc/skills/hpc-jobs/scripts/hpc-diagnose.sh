#!/usr/bin/env bash
# Maps a finished job's state and log to a likely cause and a fix.
# Usage: bash scripts/hpc-diagnose.sh JOBID JOB_DIR
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[[ $# -eq 2 ]] || die "usage: hpc-diagnose.sh JOBID JOB_DIR"
id="$1" job="$2" log="$2/logs/$1.out" found=0
hint() { printf 'cause: %s\nfix: %s\n' "$1" "$2"; found=1; }

line=$(job_line "$id")
printf '%s\n' "$line"
text=""
[[ -f "$log" ]] && text=$(tail -n 200 "$log")

case "$(awk '{print $2}' <<<"$line")" in
  OUT_OF_MEMORY) hint "the job used more memory than --mem" "raise --mem, or process the data in smaller chunks" ;;
  TIMEOUT) hint "the job hit its --time limit" "raise --time (the partition maximum applies), or checkpoint with --signal=B:USR1@300 and requeue" ;;
esac
grep -q "no kernel image is available" <<<"$text" &&
  hint "the image's PyTorch/CUDA build does not support this GPU" "rebuild on a CUDA version that supports it (Blackwell needs cu128 or newer); compare torch.cuda.get_arch_list() with nvidia-smi --query-gpu=compute_cap"
grep -q "CUDA driver version is insufficient" <<<"$text" &&
  hint "the image's CUDA is newer than the host driver" "use an image with an older CUDA, or ask the board to update the driver"
grep -qi "driver/library version mismatch" <<<"$text" &&
  hint "the NVIDIA driver was updated but the box was not rebooted" "stop and tell the board: the box needs a reboot"
grep -q "CUDA out of memory" <<<"$text" &&
  hint "the model or batch does not fit in GPU memory" "reduce the batch size, or set PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
grep -q "No space left on device" <<<"$text" &&
  hint "a disk is full" "check df -h; clean old runs with nextflow clean -f, apptainer cache clean and podman system prune"
if [[ -f "$job/.nextflow.log" ]] && grep -q "Error executing process" "$job/.nextflow.log"; then
  hint "a Nextflow process failed" "cd $job && nextflow log last -f name,exit,workdir -filter 'status == \"FAILED\"', then read .command.err in that workdir"
fi
[[ $found -eq 1 ]] || printf 'cause: unknown\nfix: read %s and %s/.nextflow.log\n' "$log" "$job"
