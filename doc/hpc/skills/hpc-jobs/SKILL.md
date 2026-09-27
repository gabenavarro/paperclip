---
name: hpc-jobs
description: Use for any work on the on-prem HPC box - container jobs under Slurm with Apptainer, job directories, GPUs, limits, checking jobs across heartbeats, failures, and GPU-hour reporting.
slug: hpc-jobs
tags:
  - hpc
  - slurm
---

# HPC jobs

You work on the HPC head node through Paperclip's ssh environment. Heavy work never runs in your own shell: submit it to Slurm, which gives each job its own CPUs, memory and GPUs.

The scripts named here are in this skill's `scripts/` folder. Run them from this skill's base directory, or give their full path.

## Rules

- **Where data goes.** Each job lives in `/data/jobs/<issue>/<job>/`, with `code/`, `inputs/`, `outputs/`, `logs/`, `work/` and `tmp/`.
  - Never put data, outputs or a Nextflow `work/` directory in your Paperclip workspace. The workspace is copied back to the Paperclip server's memory after every run, then deleted from the box.
  - Reference data in `/data/refs` is read-only.
- **Images.** Use a pinned `.sif` path from `/data/images/<name>/<tag>-<sha12>.sif` (see the hpc-ml-images skill).
- **Limits.** The defaults are 16 CPUs, 64 GB, 1 GPU and 24 h.
  - A job that needs more than 24 h or more than 1 GPU needs board approval first. Use the Paperclip skill's board-approval flow, with this issue in `issueIds`, and wait for the answer.
- **Before running a new box for the first time,** run `bash scripts/hpc-doctor.sh`. Stop and tell the board about any FAIL line.

## Submit a container job

```bash
bash scripts/hpc-submit.sh --job /data/jobs/<issue>/<job> --image <sif> [--gpus 1] [--cpus 16] [--mem 64G] [--time 1440] -- python /work/code/train.py
```

- **Inside the container:** the job directory is `/work`, and reference data is `/refs`. The container starts with a clean environment, so keep configuration in files under `/work`.
  - Link large inputs into `inputs/` with absolute paths under `/data/jobs` or `/data/refs`. The container sees both, read-only, at the same paths.
- **Without `--image`:** the command runs on the host from the job directory. Use this only for a Nextflow head job (see the hpc-nf-core skill).
- **What the script does:**
  - checks the job with `sbatch --test-only`;
  - writes the batch script to `logs/submit-<time>.sbatch`;
  - submits it;
  - sets the issue monitor, with the first check in 15 minutes and a timeout of the job's `--time` (in minutes) plus 30 minutes.
- **After it runs:**
  - Confirm that its output says `monitor: next check <time>`.
  - Comment on the issue with what the job does, why, and the `.sbatch` path, which reproduces it.
  - End your heartbeat.

## Check jobs on each monitor wake

```bash
bash scripts/hpc-status.sh --next-check <minutes> <jobid>...
```

- Back off between checks: 15, 30, 60, then 120 minutes.
- While any job is queued or running, the script schedules the next check.
- When every job has finished:
  - report the result;
  - run `bash scripts/hpc-report-gpu-hours.sh <jobid> <job-dir>` for each finished job (it reports once per job);
  - move the issue on.

## A job failed

```bash
bash scripts/hpc-diagnose.sh <jobid> /data/jobs/<issue>/<job>
```

- Apply the fix it names and resubmit.
- If it says the box needs a reboot or a driver change, stop and tell the board.

## Keep the record

Keep one issue document with key `hpc-jobs`. It is a table with one row per job: job ID, state, GPU-hours, host path, reproduce command, and image or pipeline revision. Update it on every state change. Upload small reports (up to 10 MB) as artifacts with the Paperclip skill's artifact upload script.

## Long training jobs

Add `--checkpoint` to `hpc-submit.sh`:

1. Five minutes before the time limit, Slurm sends `USR1` to the batch shell, which forwards it to your program.
2. Your training code must catch `SIGUSR1`, save a checkpoint to `/work`, and exit.
3. The batch shell then requeues the job. The same command runs again, so the code must resume from the latest checkpoint.
4. A checkpointed job has no monitor timeout. Keep checking it with `hpc-status.sh`.
