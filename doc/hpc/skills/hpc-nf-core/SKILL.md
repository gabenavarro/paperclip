---
name: hpc-nf-core
description: Use when running nf-core or other Nextflow pipelines on the HPC box - pinned versions, Slurm with Apptainer, outputs, resume, and failure diagnosis.
slug: hpc-nf-core
tags:
  - hpc
  - nextflow
---

# nf-core on the HPC box

Pipelines run with open-source Nextflow. Tasks run on Slurm in Apptainer containers. The box's settings are in `/etc/paperclip-hpc/nextflow.config`: the Slurm executor, Apptainer, a shared image cache, and a `gpu` label.

The scripts named here are in the hpc-jobs skill's `scripts/` folder.

## Run a pipeline

1. Create `/data/jobs/<issue>/<run>/`, and write the samplesheet and any params file there.
2. Pin the release. Find it on nf-co.re and never run an unpinned pipeline.
3. Submit the Nextflow head job with the hpc-jobs skill's submit script, so it survives your heartbeat:

```bash
bash <hpc-jobs skill directory>/scripts/hpc-submit.sh --job /data/jobs/<issue>/<run> --gpus 0 --cpus 2 --mem 8G --time 1440 -- \
  nextflow run nf-core/<name> -r <release> -profile apptainer -c /etc/paperclip-hpc/nextflow.config \
  --input samplesheet.csv --outdir outputs -work-dir work -resume -with-trace -with-report
```

There is no `--image`: the head job runs on the host from the run directory, because it must call `sbatch` itself. It needs no GPU. Processes that need one get it from the `gpu` label in the config.

The hpc-jobs limits apply to the head job too: a pipeline that needs more than 24 h needs board approval first. If the head job reaches its time limit, submit the same command again. `-resume` reuses the finished tasks.

## Check and finish

- Use the hpc-jobs skill's monitor loop (`hpc-status.sh`) for the head job.
- From the run directory, `nextflow log` lists runs, and `nextflow log last -f name,status,exit,duration` shows the tasks.
- When the run finishes:
  - put the MultiQC report (`outputs/multiqc/multiqc_report.html`) on the issue as an artifact, generated with `--flat` if it is over 10 MB;
  - record the pipeline release and params in the `hpc-jobs` document.

## Failures

- Run `bash <hpc-jobs skill directory>/scripts/hpc-diagnose.sh <jobid> /data/jobs/<issue>/<run>`. For a failed process, read `.command.err` in the work directory it names.
- Fix the input or the params, then resubmit the same command. `-resume` reuses finished tasks.

## Clean up

After the results are recorded, free the space: `nextflow clean -before <run-name> -f` from the run directory.
