---
title: HPC Agents
summary: Run expert agents on on-prem HPC boxes through the ssh environment
---

Paperclip agents can run on an on-prem HPC box, reached over a VPN through Paperclip's `ssh` environment. On the box, they hand heavy work to Slurm, Apptainer and Nextflow. This guide sets up one box and imports the HPC agents package from `doc/hpc/`.

The design is in `doc/plans/2026-09-25-hpc-agents-over-ssh.md`.

## 1. Prepare the box

As an administrator on the box (Ubuntu 24.04):

1. Create a dedicated `paperclip` user with no sudo and no `docker` group. Set `PATH` in `~/.profile`, because non-interactive shells skip `~/.bashrc`.
2. Install the NVIDIA driver (570 or later for Blackwell), then hold the driver packages and the running kernel with `apt-mark hold`.
3. Install Slurm for one node: `apt install slurm-wlm munge slurm-wlm-nvml-plugin`.
   - `slurm.conf`:
     - `SelectType=select/cons_tres`, `ProctrackType=proctrack/cgroup`, `TaskPlugin=task/cgroup,task/affinity`
     - `GresTypes=gpu`, `JobCompType=jobcomp/filetxt`, `JobCompLoc=/var/log/slurm/jobcomp.log`
     - `JobAcctGatherType=jobacct_gather/cgroup`, `AccountingStorageTRES=gres/gpu`
     - a partition with `DefaultTime=04:00:00` and `MaxTime=7-00:00:00`
   - `gres.conf`: `AutoDetect=nvml`.
   - `cgroup.conf`: `ConstrainCores=yes`, `ConstrainRAMSpace=yes`, `ConstrainDevices=yes`.
4. Install Apptainer, and rootless Podman with subuid/subgid ranges for `paperclip`.
5. Install Java 17, Nextflow, Node.js 22, git, curl, jq and the Claude Code CLI for the `paperclip` user.
6. Create `/data/jobs` (writable), `/data/refs` (read-only in jobs), `/data/images` and `/data/cache/apptainer`.
7. Write `/etc/paperclip-hpc/nextflow.config`:
   - `process.executor = 'slurm'`
   - `apptainer.enabled = true`
   - `apptainer.cacheDir = '/data/cache/apptainer'`
   - `withLabel: gpu { clusterOptions = '--gres=gpu:1'; containerOptions = '--nv' }`
8. Put the Google credential for Vertex AI in `/etc/paperclip/gcp-credentials.json` (mode `0600`, owned by `paperclip`). Use a Workload Identity Federation config if you have an identity provider. Otherwise use a service-account key with only the Vertex AI User role.
9. In `/etc/ssh/sshd_config`, set `MaxSessions 64`, then reload sshd. Paperclip sends all of its commands to the box over one shared ssh connection, and the default allows only 10 sessions per connection.

## 2. Connect Paperclip

1. Route the Cloud Run VPC to the site (HA VPN or Interconnect). Allow TCP 22 from the Cloud Run subnet only.
   - Paperclip's ssh sends a keepalive every 15 s and closes the connection after about 60 s with no reply. A VPN outage longer than a minute fails every run on the box.
2. In Paperclip, turn on **Instance Settings → Experimental → Environments**.
3. Create an **SSH** environment:
   - host, and user `paperclip`
   - the private key as a secret
   - the pinned host key
   - remote workspace `/home/paperclip/paperclip-workspaces`
4. Add these environment variables:
   - `CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_PROJECT_ID=<project>`, `CLOUD_ML_REGION=global`
   - `GOOGLE_APPLICATION_CREDENTIALS=/etc/paperclip/gcp-credentials.json`
   - `NXF_VER=<version>`, `DISABLE_AUTOUPDATER=1`
   - optionally `HPC_GPU_HOUR_CENTS=<cents>`

   Test the connection.

## 3. Import the agents

Import from GitHub, not a local folder: local imports drop the helper scripts.

```bash
paperclipai company import gabenavarro/paperclip/doc/hpc --ref master --target existing -C <companyId> \
  --include agents,projects,tasks,skills --collision skip --dry-run
paperclipai company import gabenavarro/paperclip/doc/hpc --ref master --target existing -C <companyId> \
  --include agents,projects,tasks,skills --collision skip --yes
```

After the import:

1. Set each HPC agent's default environment to the SSH environment (the agent's settings, or `PATCH /api/agents/:id` with `defaultEnvironmentId`).
2. To skip digests on quiet days, set the daily digest routine to run only after activity: `PATCH /api/routines/:id` with `{"activityGatePolicy":"require_external_activity"}`.
3. Give one agent a small issue: "Run `bash scripts/hpc-doctor.sh` and report." Every line should be PASS.
