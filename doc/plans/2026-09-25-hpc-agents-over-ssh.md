# HPC Agents over SSH

Status: proposed, for review. Issue: #5.

## Goal

Paperclip agents run heavy ML and bioinformatics work on on-prem HPC boxes. A typical box has 128 CPUs, 512 GiB RAM and a 96 GB Blackwell-class GPU. The agents can:

1. hand off well-defined jobs to containers,
2. run their own code in containers, with mounted job directories,
3. build new images when ML libraries change (PyTorch, Hugging Face, CUDA),
4. run nf-core multi-step pipelines.

Only internal systems are used: the company GCP project and the on-prem boxes.

## Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | Internal systems only. No Seqera Platform and no hosted Wave. | Run metadata and logs stay on company systems. |
| D2 | Agents work from the HPC through Paperclip's built-in `ssh` environment. | Agents get a real shell to submit and debug jobs. There is no new service to run, and the work hardens an existing feature. |
| D3 | Jobs run under single-node Slurm with GPU GRES. | The Nextflow local executor does not keep concurrent jobs off the same GPU. Slurm does. |
| D4 | Containers run with Apptainer. Images are built from Dockerfiles with rootless Podman. | Apptainer runs inside the Slurm job, so Slurm's cgroup limits apply. Docker containers start outside the job. Agents never join the `docker` group, because that group is root-equivalent. |
| D5 | nf-core runs with open-source Nextflow: `-profile apptainer` plus a local Slurm config. | nf-core does not need Seqera. |
| D6 | Expert agents use company skills. | The skills hold the conventions below, and they are versioned in this repo. |

## Architecture

```
Paperclip on Cloud Run (company GCP project)
   │ ssh over the VPN (reused connection)
   ▼
HPC box, account "paperclip"
   agent CLI (Claude Code or Gemini CLI, via Vertex AI)
   ├─ sbatch + apptainer ─► container jobs, GPUs by Slurm
   ├─ nextflow ─► nf-core pipelines on Slurm
   └─ podman build ─► Apptainer image (.sif), pinned
   /data/jobs    job code, inputs links, outputs, logs
   /data/refs    reference data (read-only in jobs)
   /data/images  images and their manifest
```

The agent's Paperclip workspace holds only small files: notes, scripts and configs. Job data lives under `/data/jobs`.

## Part 1: harden the `ssh` environment (code)

A code review of `packages/adapter-utils/src/ssh.ts`, `sandbox-callback-bridge.ts`, `remote-managed-runtime.ts` and `execution-target.ts` found five problems. Each item below is a finding and then its change. Write each test first. `ssh-fixture.test.ts` runs a real `sshd` with VERBOSE logs, so a test can count `Accepted publickey` lines.

1. **Connection reuse.**
   - Finding: each operation starts a new `ssh` login, including the callback bridge's poll every 100 ms. Over a VPN that is about 40–150 logins per minute per run. There is no keepalive, so a VPN drop is found only after about 2 hours.
   - Change: in `createSshAuthArgs`, add `ControlMaster=auto`, `ControlPath=<0700 dir>/%C`, `ControlPersist=120`, `ServerAliveInterval=15` and `ServerAliveCountMax=4`.
   - Test: several commands produce one login.
   - Risk: a backgrounded master can hold the caller's stderr pipe open, so `execFile` waits until `ControlPersist` ends. Test this first. The fallback is to start the master explicitly (`ssh -MNf`) and use `ControlMaster=no` for each call.
2. **Slower bridge polling.** Poll every 1000 ms for `ssh` targets, not every 100 ms.
3. **Env off argv.**
   - Finding: the agent env, including API keys, goes in the `ssh` argv (`exec env K='V' …`). The local argv keeps the keys for the whole run, and the remote `ps` shows them until the `exec`.
   - Change: send `export K=V` lines over stdin into a `0600` temp file, then source it, delete it and `exec` the command. The helper already supports stdin. This covers the runner script, the helper command and the agent command in `ssh.ts`.
   - Test: no secret value appears in the `ssh` argv, and the command still sees the env.
4. **Remote cleanup.** The per-run copy at `<remoteWorkspacePath>/.paperclip-runtime/runs/<runId>` is never deleted. Delete it after a successful restore.
5. **Timeouts.** A helper timeout of `0` means "no timeout", and a real `execFile` timeout (`killed`, SIGTERM) is not detected. Make `0` use the default, and count `killed`/SIGTERM as a timeout.

Verify with the unit tests above. Also run `server/src/__tests__/environment-live-ssh.test.ts` against a real box with `PAPERCLIP_ENV_LIVE_SSH_*`.

## Part 2: connect Cloud Run to the HPC (configuration)

- **Network.** Route from the VPC to the site (HA VPN or Interconnect). This is outside Paperclip. Cloud Run already sends private ranges into the VPC (`--vpc-egress private-ranges-only`).
- **Firewall and `sshd`.** Allow TCP 22 only from the Cloud Run subnet. Set `AllowUsers paperclip`.
- **Paperclip.**
  1. Turn on Instance Settings → Experimental → Environments.
  2. Create an `ssh` environment:
     - host, port, and user `paperclip`
     - `remoteWorkspacePath` set to `/home/paperclip/paperclip-workspaces`
     - the private key from a Paperclip secret
     - a pinned `knownHosts`
     - an explicit `timeoutSec`
  3. Run the connection test.
- **Model access (env vars on the environment).** The credential file is placed on the box by hand with mode `0600`, because Paperclip cannot write a secret to a file.
  - Claude Code on Vertex AI: `CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION=global`. Claude models need a one-time Model Garden approval.
  - Gemini CLI on Vertex AI: `GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION=global`.
  - Both: `GOOGLE_APPLICATION_CREDENTIALS=/etc/paperclip/gcp-credentials.json`. This is a Workload Identity Federation config, or a service-account key with only the Vertex AI User role.
- **Agents use `engine: "cli"`.** The default ACP engine rejects `ssh` targets.

## Part 3: set up each HPC box (runbook)

1. **Account.** Create a dedicated `paperclip` user with no sudo and no `docker` group. Gemini CLI and OpenCode delete `~/.gemini/skills` and `~/.claude/skills` in the home directory, so the account must be dedicated.
2. **GPU.** Install an NVIDIA driver version 570 or later (Blackwell). Apptainer's `--nv` binds the driver libraries itself, so no container toolkit is needed.
3. **Slurm, single node.**
   - Ubuntu 24.04: `slurm-wlm munge slurm-wlm-nvml-plugin`. Rocky 9: the OpenHPC 3.x repo.
   - `slurm.conf`: `SelectType=select/cons_tres`, `ProctrackType=proctrack/cgroup`, `TaskPlugin=task/cgroup,task/affinity`, `GresTypes=gpu`, and a `NodeName` line with CPUs, `RealMemory` and `Gres`.
   - `gres.conf`: `AutoDetect=nvml`.
   - `cgroup.conf`: `ConstrainCores`, `ConstrainRAMSpace` and `ConstrainDevices`, all set to `yes`.
4. **Apptainer, and rootless Podman** with subuid/subgid ranges for `paperclip`.
5. **Nextflow** (Java 17 or later), plus `/etc/paperclip-hpc/nextflow.config`. Nextflow fetches nf-core pipelines itself. The config sets:
   - `process.executor = 'slurm'`
   - `apptainer.enabled = true`
   - `apptainer.cacheDir = '/data/cache/apptainer'`
   - a `gpu` label that sets `clusterOptions = '--gres=gpu:1'` and `containerOptions = '--nv'`
6. **Agent runtime.** Node.js 22 or later, git, tar, and the agent CLIs (`claude`, `gemini`) on the login-profile `PATH`.
7. **Directories.**
   - `/data/jobs`: read-write for `paperclip`.
   - `/data/refs`: read-only in jobs.
   - `/data/images`: `.sif` files.
8. **Smoke tests.**
   - `sbatch --gres=gpu:1 --wrap "apptainer exec --nv <image> nvidia-smi -L"`. It must show exactly one GPU.
   - `nextflow run nf-core/demo -r <tag> -profile test,apptainer -c /etc/paperclip-hpc/nextflow.config`.
   - A Podman build that becomes a `.sif` and runs with `--nv`.

## Part 4: job conventions (the skills teach these)

- **Job directory.**
  - Layout: `/data/jobs/<issue>/<job>/` with `code/`, `inputs/` (links), `outputs/`, `logs/` and `work/`. The issue comment holds what, why, and the command that reproduces the job.
  - Never keep job data or a Nextflow `work/` directory in the Paperclip workspace. The workspace is copied back to Cloud Run's in-memory disk after each run.
- **Container job.**
  ```
  sbatch --gres=gpu:1 --cpus-per-task=16 --mem=64G --time=24:00:00 \
    --output=/data/jobs/<issue>/<job>/logs/%j.out \
    --wrap "apptainer exec --nv --containall \
      --bind /data/jobs/<issue>/<job>:/work --bind /data/refs:/refs:ro \
      /data/images/<name>/<tag>-<sha12>.sif python /work/code/train.py"
  ```
- **nf-core.**
  ```
  nextflow run nf-core/<name> -r <tag> -profile apptainer \
    -c /etc/paperclip-hpc/nextflow.config \
    --outdir /data/jobs/<issue>/<job>/outputs \
    -work-dir /data/jobs/<issue>/<job>/work -resume -with-trace -with-report
  ```
  Run the Nextflow head job as its own `sbatch` job, so it survives the agent's run.
- **New image.**
  1. Write the Dockerfile under `/data/images/src/<name>/`. Pin the base with `FROM …@sha256:<digest>` and record versions with `LABEL cuda=… torch=…`. `apptainer inspect` shows the labels.
  2. Build and export: `podman build` → `podman save -o <tar>` → `apptainer build /data/images/<name>/<tag>-<sha12>.sif docker-archive:<tar>`.
  3. Before a CUDA change, compare `nvidia-smi` with the CUDA version. Blackwell needs CUDA 12.8 or later, CUDA 12.x needs driver 525 or later, and CUDA 13.x needs driver 580 or later.
- **Long work.** Submit the job and write the Slurm job ID on the issue, then end the heartbeat. Later heartbeats check `squeue`, `sacct` or `nextflow log` and report.
- **Default limits.** 16 CPUs, 64 GB, 1 GPU and 24 h, unless the issue asks for more.

## Part 5: skills and expert agents (configuration)

Skills are markdown, versioned in `doc/hpc/skills/<slug>/SKILL.md`. Import them into the company library pinned to a commit (`POST /api/companies/:companyId/skills/import`). No code change is needed.

| Skill | Covers |
|---|---|
| `hpc-jobs` | job directories, `sbatch` + Apptainer, GPUs, limits, status across heartbeats |
| `hpc-nf-core` | nf-core with Nextflow on Slurm + Apptainer, versions, `-resume`, outputs |
| `hpc-ml-images` | Dockerfile → Podman → `.sif`, CUDA and driver rules, pinning, labels |

| Agent | Skills | Adapter |
|---|---|---|
| HPC Pipeline Engineer | `hpc-jobs`, `hpc-nf-core` | `claude_local`, `engine: "cli"`, the HPC `ssh` environment |
| ML Environment Engineer | `hpc-jobs`, `hpc-ml-images` | same |

## Security

Parts 1–3 hold the controls: a dedicated account, no `docker` group, rootless builds, Slurm cgroups, env off argv, a pinned host key, and `sshd` reachable only over the VPN. Two more points:

- On `ssh` targets the agent CLIs skip permission prompts. The account's Unix rights are the boundary.
- What an agent reads goes to the model through Vertex AI in the company project. Raw data stays on the box.

## Open questions (defaults in brackets)

1. GPUs per box and sharing. [One whole GPU per job. Add Slurm shards if single-GPU boxes queue too much.]
2. Models. [Claude via Vertex AI for both agents, with Gemini via Vertex AI as the alternative. Codex is left out because it needs the OpenAI API.]
3. Credential to Vertex AI. [Workload Identity Federation if an OIDC or SAML provider or an X.509 CA exists. Otherwise a service-account key with only the Vertex AI User role.]
4. Linux distribution. [Ubuntu 24.04.]
5. Number of boxes. [One box first, with one `ssh` environment per box.]

## Phases

1. `ssh` hardening PR (Part 1).
2. Box setup and smoke tests (Part 3).
3. VPN and the `ssh` environment (Part 2).
4. Skills, agents, and an end-to-end check (Parts 4–5): a GPU job, `nf-core/demo`, and an image update.
5. Docs: `docs/deploy/hpc-agents.md`.

## Skipped until needed

| Skipped | Add when |
|---|---|
| Seqera Platform and Wave | a self-hosted license is bought |
| A job API or MCP service on the HPC | agents must stay on Cloud Run |
| A local image registry (Zot) | several boxes have no shared storage |
| An `ssh` duplex channel; a probe for node, git and the agent CLIs | 1 s polling is too slow, or setup errors are hard to find |
| A guided HPC setup script | more than one box, or the distribution is fixed |
| OpenCode or Codex agents | a local model is served with vLLM |
| MIG or MPS | whole-GPU scheduling is too coarse |

## Risks

- The `ssh` environment is experimental, so real load can show more issues. Run the live test early.
- `ControlPersist` can hang `execFile` (Part 1.1). Test it first.
- The restore copies workspace files back to Cloud Run memory. The skill rule keeps data out, and a size cap can come later.
- After a Cloud Run restart, the bridge gateway keeps running on the box. Clean it up later.

## Sources

- CUDA driver compatibility: https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html
- Slurm GRES, cgroups and containers: https://slurm.schedmd.com/gres.html, https://slurm.schedmd.com/cgroup.conf.html, https://slurm.schedmd.com/containers.html
- Ubuntu NVML plugin package: https://launchpad.net/ubuntu/noble/+package/slurm-wlm-nvml-plugin
- Apptainer GPUs and Docker archives: https://apptainer.org/docs/user/main/gpu.html, https://apptainer.org/docs/user/main/docker_and_oci.html
- Nextflow on Slurm (GPUs through `clusterOptions`): https://docs.seqera.io/nextflow/executor/slurm
- nf-core offline download: https://nf-co.re/docs/nf-core-tools/cli/pipelines/download
- Rootless Podman: https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- Claude Code on Vertex AI: https://code.claude.com/docs/en/google-vertex-ai
- Workload Identity Federation: https://cloud.google.com/iam/docs/workload-identity-federation-with-other-providers
