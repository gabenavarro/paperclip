---
name: hpc-ml-images
description: Use when a job needs a new or updated ML container image (PyTorch, Hugging Face, CUDA) on the HPC box - Dockerfile, rootless Podman build, pinned Apptainer image, and the CUDA driver check.
slug: hpc-ml-images
tags:
  - hpc
  - containers
---

# HPC ML images

Images are Dockerfiles, built with rootless Podman and stored as pinned Apptainer images: `/data/images/<name>/<tag>-<sha12>.sif`. Jobs use that exact path. Never use a moving tag.

`scripts/hpc-build-image.sh` is in this skill's folder. The GPU check uses `scripts/hpc-submit.sh` from the hpc-jobs skill's folder.

## Before a CUDA or PyTorch change

1. Read the host: `nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader`.
2. Driver minimums: CUDA 12.x needs driver 525 or later, and CUDA 13.x needs 580 or later.
3. Blackwell GPUs (compute capability 12.0, `sm_120`) need a PyTorch build for CUDA 12.8 or later (`cu128` or newer).

## Write the Dockerfile

Put it in `/data/images/src/<name>/Dockerfile`:

- Pin the base by digest: `FROM pytorch/pytorch@sha256:<digest>`. Find the digest with `podman pull` and `podman inspect --format '{{.Digest}}'`.
- Add versions as labels, for example `LABEL cuda="12.8" torch="2.8.0" transformers="4.56.0"`. `apptainer inspect --labels` prints them later.
- Install Hugging Face and other Python packages with pinned versions (`pip install transformers==<version>`).

## Build

```bash
bash scripts/hpc-build-image.sh <name> <tag> /data/images/src/<name>
```

It prints `image: /data/images/<name>/<tag>-<sha12>.sif`. Building needs no GPU.

## Check it on the GPU

Submit a short test job with the hpc-jobs skill's submit script:

```bash
bash <hpc-jobs skill directory>/scripts/hpc-submit.sh --job /data/jobs/<issue>/image-check --image <sif> --time 10 -- python -c "import torch; print(torch.cuda.get_arch_list(), torch.cuda.is_available())"
```

The arch list must include the GPU's `sm_XY`. Put the image path, its labels and the check result in an issue comment.
