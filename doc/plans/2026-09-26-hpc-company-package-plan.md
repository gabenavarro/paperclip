# HPC Company Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `doc/hpc/`, a Paperclip company package. It holds two expert HPC agents, three skills with tested helper scripts, a project and two routines. One `paperclipai company import` adds them to an existing company.

**Architecture:** This is content only; no server code changes. The skills are markdown plus bash helpers that run on the HPC head node, where Slurm, Apptainer, Podman and `jq` are installed. Node `--test` tests run the helpers against fake `sbatch`, `squeue`, `apptainer`, `podman`, `curl` and similar commands on `PATH`. A server test previews the package with Paperclip's real importer, so format mistakes fail CI.

**Tech Stack:** Bash 5 (GNU coreutils: `date -d`, `realpath -m`, `sha256sum`, `stat -c`), `jq`, Node 24 `node:test`, Vitest (server test), Paperclip company-package format (`agentcompanies/v1`, `.paperclip.yaml` schema version 7).

**Spec:** `doc/plans/2026-09-25-hpc-agents-over-ssh.md` (Parts 4–6). Issue #5. Plan A (`doc/plans/2026-09-25-ssh-environment-hardening-plan.md`, Task 5) adds the cost-events route that `hpc-report-gpu-hours.sh` uses.

## Global Constraints

- Internal systems only. Add no dependency and no external service.
- Default limits: 16 CPUs, 64 GB, 1 GPU and 24 h. More than 24 h or more than 1 GPU needs board approval.
- Paths: `/data/jobs/<issue>/<job>/`, `/data/refs` (read-only in jobs), `/data/images/<name>/<tag>-<sha12>.sif`, completion log `/var/log/slurm/jobcomp.log`. Scripts read `HPC_JOBS_ROOT`, `HPC_REFS_ROOT`, `HPC_IMAGES_ROOT` and `HPC_JOBCOMP_LOG` so tests can override them.
- The monitor PATCH replaces the whole `executionPolicy` (`server/src/routes/issues.ts:13124-13128`). Scripts must read the issue and merge `executionPolicy.monitor` into it. The Slurm job ID goes in `notes`, not `externalRef`, which Paperclip redacts.
- Mutating API calls send `Authorization: Bearer $PAPERCLIP_API_KEY` and `X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID` (`skills/paperclip/SKILL.md:28`).
- Package format rules (`server/src/services/company-portability.ts:2736-2884`): Paperclip's YAML parser is hand-written.
  - Use exactly 2-space nesting. Indent `- ` list items 2 spaces under their key, and item keys 2 spaces past the dash.
  - No `>` or `|` block text, no `# comments` after values, double quotes only.
  - Never set `metadata.sources` in a `SKILL.md`, or scripts are rejected.
  - `agents/<slug>/AGENTS.md` is the exact filename.
- Scripts in imported skills lose the exec bit. Skills call them as `bash scripts/<name>.sh`.
- Import from GitHub, never a local folder: local imports drop the scripts. Always pass `--include agents,projects,tasks,skills`, because including `company` would clear the company logo.
- The repo is public. Write no internal hostnames, project IDs or IPs. Only `gabenavarro` merges. Commits end with the Claude Code attribution trailer.

## Review Focus

These are the five input classes the tests below must pin:

1. An issue that already has review stages keeps them after `hpc-submit.sh` sets its monitor (Task 2, submit test asserts `stages.length`).
2. A job directory outside `HPC_JOBS_ROOT`, or a rejected `sbatch --test-only`, submits nothing (Task 2, the refuse and rejected tests).
3. Slurm time limits in every accepted form: `MM`, `MM:SS`, `HH:MM:SS`, `D-HH`, `D-HH:MM` (Task 2, time test).
4. Running `hpc-report-gpu-hours.sh` twice for the same job posts one cost event (Task 3, report test).
5. Package YAML that the hand-written parser silently skips must fail the preview test. It asserts exact adapter, runtime, skill-file and routine values, not just "no errors" (Tasks 1 and 7).

---

### Task 1: Package skeleton and import-preview test

**Files:**
- Create: `doc/hpc/COMPANY.md`, `doc/hpc/.paperclip.yaml`, `doc/hpc/projects/hpc/PROJECT.md`
- Modify: `server/src/__tests__/company-portability.test.ts` (add one `describe` block at the end of the file)

**Interfaces:**
- Produces: the `doc/hpc/` root that later tasks add to, and the test `"doc/hpc company package"`, which later tasks extend with assertions.

- [ ] **Step 1: Write the failing test.** Append to `server/src/__tests__/company-portability.test.ts`. It reuses the file's module-level mocks (`agentSvc`, `projectSvc`, `companySkillSvc`, `companySvc`) and imports (`fs`, `path`):

```ts
describe("doc/hpc company package", () => {
  async function readPackageFiles(): Promise<Record<string, string>> {
    const root = path.resolve(import.meta.dirname, "../../../doc/hpc");
    const files: Record<string, string> = {};
    for (const entry of await fs.readdir(root, { recursive: true, withFileTypes: true })) {
      if (!entry.isFile()) continue;
      const absolute = path.join(entry.parentPath, entry.name);
      files[path.relative(root, absolute).split(path.sep).join("/")] = await fs.readFile(absolute, "utf8");
    }
    return files;
  }

  async function previewPackage() {
    agentSvc.list.mockResolvedValue([]);
    projectSvc.list.mockResolvedValue([]);
    companySkillSvc.listFull.mockResolvedValue([]);
    companySvc.getById.mockResolvedValue({ id: "company-1", name: "Test Co", issuePrefix: "TST" });
    return companyPortabilityService({} as any).previewImport({
      source: { type: "inline", rootPath: "hpc", files: await readPackageFiles() },
      include: { company: false, agents: true, projects: true, issues: true, skills: true },
      target: { mode: "existing_company", companyId: "company-1" },
      agents: "all",
      collisionStrategy: "skip",
    });
  }

  it("previews cleanly as an import into an existing company", async () => {
    const preview = await previewPackage();

    expect(preview.errors).toEqual([]);
    expect(preview.warnings).toEqual([]);
    expect(preview.manifest.projects.map((project) => project.slug)).toEqual(["hpc"]);
  });
});
```

- [ ] **Step 2: Run it and see it fail.**

Run: `npx vitest run server/src/__tests__/company-portability.test.ts -t "doc/hpc company package"`
Expected: FAIL with `ENOENT: no such file or directory, scandir '…/doc/hpc'`.

- [ ] **Step 3: Create the skeleton.**

`doc/hpc/COMPANY.md`:

```markdown
---
schema: agentcompanies/v1
name: HPC Agents
slug: hpc-agents
description: Expert agents that run container jobs, nf-core pipelines and ML image builds on on-prem HPC boxes through Paperclip's ssh environment.
---

# HPC Agents

Two agents, three skills, one project and two routines for on-prem HPC work. Setup and the import command are in `docs/deploy/hpc-agents.md`.
```

`doc/hpc/.paperclip.yaml`:

```yaml
schema: paperclip/v1
schemaVersion: 7
```

`doc/hpc/projects/hpc/PROJECT.md`:

```markdown
---
name: HPC
slug: hpc
description: Container jobs, nf-core pipelines and ML images on the on-prem HPC boxes.
---

# HPC

Work that runs on the on-prem HPC boxes. Job data lives under `/data/jobs/<issue>/`.
```

- [ ] **Step 4: Run it and see it pass.**

Run: `npx vitest run server/src/__tests__/company-portability.test.ts -t "doc/hpc company package"`
Expected: PASS. If `previewImport` needs another mock for an existing-company target, add the smallest `mockResolvedValue` that makes it run and note it in the report.

- [ ] **Step 5: Commit.**

```bash
git add doc/hpc server/src/__tests__/company-portability.test.ts
git commit -m "feat(hpc): company package skeleton with an import-preview test"
```

---

### Task 2: `hpc-jobs` helpers `lib.sh` and `hpc-submit.sh`

**Files:**
- Create: `doc/hpc/skills/hpc-jobs/scripts/lib.sh`, `doc/hpc/skills/hpc-jobs/scripts/hpc-submit.sh`
- Create: `scripts/hpc-skills.test.mjs` (harness plus this task's tests)
- Modify: `package.json` (add `"test:hpc-skills": "node --test scripts/hpc-skills.test.mjs"` next to `test:gcp-cloud-run`)

**Interfaces:**
- Produces, from `lib.sh`:
  - `die MESSAGE`: exits 2.
  - `iso_in SECONDS`: prints a UTC ISO time.
  - `slurm_time_to_seconds T`.
  - `field KEY LINE`: prints the value of `KEY=value`.
  - `job_line JOBID`: prints `<id> <STATE> <details>`.
  - `api_request METHOD PATH [BODY]`.
  - `schedule_monitor MINUTES NOTES [TIMEOUT_SECONDS]`.
- Produces, in the test harness: `sandbox()`, `run()`, `apiEnv` and `ISSUE`, reused by Tasks 3–5.

- [ ] **Step 1: Write the failing tests.** Create `scripts/hpc-skills.test.mjs`:

```js
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const repo = path.resolve(import.meta.dirname, "..");
const jobsScripts = path.join(repo, "doc/hpc/skills/hpc-jobs/scripts");
const imagesScripts = path.join(repo, "doc/hpc/skills/hpc-ml-images/scripts");

// Fake HPC commands. Each logs its call to $FAKE_LOG and prints canned output.
const FAKES = {
  sbatch: `printf 'sbatch %s\\n' "$*" >> "$FAKE_LOG"
for a in "$@"; do
  if [ "$a" = "--test-only" ]; then echo "sbatch: Job 4242 to start at 2026-09-26T10:00:00 using 16 processors" >&2; exit "\${FAKE_SBATCH_TEST_EXIT:-0}"; fi
done
echo 4242`,
  squeue: `id=""
while [ $# -gt 0 ]; do [ "$1" = "-j" ] && id="$2"; shift; done
if [ -n "\${FAKE_SQUEUE:-}" ] && [ "\${FAKE_SQUEUE%% *}" = "$id" ]; then printf '%s\\n' "$FAKE_SQUEUE"; fi
exit 0`,
  sinfo: `echo "gpu:1"`,
  "nvidia-smi": `echo "NVIDIA RTX PRO 6000, 575.51, 12.0"`,
  nextflow: `echo "nextflow version 25.04.6"`,
  claude: `echo "2.1.0"`,
  apptainer: `printf 'apptainer %s\\n' "$*" >> "$FAKE_LOG"
case "$1" in
  --version) echo "apptainer version 1.4.1" ;;
  build) printf 'fake sif\\n' > "$2" ;;
  inspect) echo "cuda: 12.8" ;;
esac`,
  podman: `printf 'podman %s\\n' "$*" >> "$FAKE_LOG"
case "$1" in
  info) echo "\${FAKE_PODMAN_INFO:-true overlay}" ;;
  save) while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then printf 'tar' > "$2"; fi; shift; done ;;
esac`,
  curl: `method=GET; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s %s %s\\n' "$method" "$url" "$data" >> "$FAKE_LOG"
case "$method" in
  GET) printf '%s' "$FAKE_ISSUE_JSON" ;;
  PATCH) printf '%s' "$data" | jq -c '{monitorNextCheckAt: .executionPolicy.monitor.nextCheckAt, executionPolicy}' ;;
  POST) printf '{"id":"cost-1"}' ;;
esac`,
};

function sandbox() {
  const root = mkdtempSync(path.join(os.tmpdir(), "hpc-skills-"));
  const bin = path.join(root, "bin");
  mkdirSync(bin);
  for (const [name, body] of Object.entries(FAKES)) {
    writeFileSync(path.join(bin, name), `#!/usr/bin/env bash\n${body}\n`);
    chmodSync(path.join(bin, name), 0o755);
  }
  for (const dir of ["jobs", "refs", "images"]) mkdirSync(path.join(root, dir));
  const image = path.join(root, "images", "demo.sif");
  writeFileSync(image, "sif");
  const log = path.join(root, "calls.log");
  writeFileSync(log, "");
  const env = {
    PATH: `${bin}:${process.env.PATH}`,
    HOME: root,
    HPC_JOBS_ROOT: path.join(root, "jobs"),
    HPC_REFS_ROOT: path.join(root, "refs"),
    HPC_IMAGES_ROOT: path.join(root, "images"),
    HPC_JOBCOMP_LOG: path.join(root, "jobcomp.log"),
    FAKE_LOG: log,
  };
  return { root, image, log, env };
}

function run(script, args, env) {
  return spawnSync("bash", [script, ...args], { env, encoding: "utf8" });
}

const apiEnv = {
  PAPERCLIP_API_URL: "http://127.0.0.1:9",
  PAPERCLIP_API_KEY: "bridge-token",
  PAPERCLIP_TASK_ID: "issue-1",
  PAPERCLIP_RUN_ID: "run-1",
  PAPERCLIP_AGENT_ID: "11111111-1111-4111-8111-111111111111",
  PAPERCLIP_COMPANY_ID: "company-1",
};
const ISSUE = JSON.stringify({
  id: "issue-1",
  executionPolicy: { mode: "normal", commentRequired: true, stages: [{ type: "review", participants: [] }] },
});

test("slurm_time_to_seconds parses every Slurm time-limit form", () => {
  const lib = JSON.stringify(path.join(jobsScripts, "lib.sh"));
  const out = spawnSync(
    "bash",
    ["-c", `. ${lib}; for t in 24:00:00 1-00:00 90 30:00 2-12; do slurm_time_to_seconds "$t"; done`],
    { encoding: "utf8" },
  );
  assert.equal(out.stdout, "86400\n86400\n5400\n1800\n216000\n", out.stderr);
});

test("hpc-submit validates, submits, and merges the monitor into the issue policy", () => {
  const s = sandbox();
  const job = path.join(s.env.HPC_JOBS_ROOT, "ISS-1", "train");
  mkdirSync(job, { recursive: true });

  const r = run(
    path.join(jobsScripts, "hpc-submit.sh"),
    ["--job", job, "--image", s.image, "--", "python", "/work/code/train.py", "--lr", "3e-4"],
    { ...s.env, ...apiEnv, FAKE_ISSUE_JSON: ISSUE },
  );

  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^submitted 4242 /m);
  assert.match(r.stdout, /monitor: next check \d{4}-\d{2}-\d{2}T/);
  const calls = readFileSync(s.log, "utf8");
  assert.match(calls, /sbatch .*--test-only/);
  assert.match(calls, /sbatch .*--parsable .*--gres gpu:1/);
  const script = readdirSync(path.join(job, "logs")).find((file) => file.endsWith(".sbatch"));
  const body = readFileSync(path.join(job, "logs", script), "utf8");
  assert.match(body, /apptainer exec --nv --containall/);
  assert.match(body, /--bind \S+:\/refs:ro/);
  assert.match(body, /python \/work\/code\/train\.py --lr 3e-4/);
  const patch = calls.split("\n").find((line) => line.startsWith("PATCH "));
  const sent = JSON.parse(patch.slice(patch.indexOf("{")));
  assert.equal(sent.executionPolicy.stages.length, 1, "the existing review stage must be kept");
  assert.equal(sent.executionPolicy.monitor.kind, "external_service");
  assert.equal(sent.executionPolicy.monitor.serviceName, "slurm");
  assert.match(sent.executionPolicy.monitor.notes, /slurm job 4242/);
  assert.ok(sent.executionPolicy.monitor.timeoutAt);
});

test("hpc-submit refuses a job directory outside HPC_JOBS_ROOT", () => {
  const s = sandbox();

  const r = run(path.join(jobsScripts, "hpc-submit.sh"), ["--job", s.root, "--image", s.image, "--", "true"], s.env);

  assert.equal(r.status, 2);
  assert.match(r.stderr, /must be under/);
  assert.equal(readFileSync(s.log, "utf8"), "");
});

test("hpc-submit submits nothing when sbatch --test-only rejects the job", () => {
  const s = sandbox();
  const job = path.join(s.env.HPC_JOBS_ROOT, "ISS-1", "bad");
  mkdirSync(job, { recursive: true });

  const r = run(path.join(jobsScripts, "hpc-submit.sh"), ["--job", job, "--image", s.image, "--", "true"], {
    ...s.env,
    FAKE_SBATCH_TEST_EXIT: "1",
  });

  assert.equal(r.status, 2);
  assert.match(r.stderr, /rejected/);
  assert.doesNotMatch(readFileSync(s.log, "utf8"), /--parsable/);
});

test("hpc-submit runs a host command from the job directory, and --checkpoint requeues on USR1", () => {
  const s = sandbox();
  const job = path.join(s.env.HPC_JOBS_ROOT, "ISS-1", "pipeline");
  mkdirSync(job, { recursive: true });

  const host = run(path.join(jobsScripts, "hpc-submit.sh"), ["--job", job, "--gpus", "0", "--", "nextflow", "run", "nf-core/demo"], s.env);
  assert.equal(host.status, 0, host.stderr);
  const hostScript = readdirSync(path.join(job, "logs")).find((file) => file.endsWith(".sbatch"));
  const hostBody = readFileSync(path.join(job, "logs", hostScript), "utf8");
  assert.ok(hostBody.split("\n").includes(`cd ${job}`), hostBody);
  assert.match(hostBody, /^exec nextflow run nf-core\/demo/m);
  assert.doesNotMatch(hostBody, /apptainer/);
  assert.doesNotMatch(readFileSync(s.log, "utf8"), /--gres/);

  const trainJob = path.join(s.env.HPC_JOBS_ROOT, "ISS-1", "long-train");
  mkdirSync(trainJob, { recursive: true });
  const ckpt = run(path.join(jobsScripts, "hpc-submit.sh"), ["--job", trainJob, "--image", s.image, "--checkpoint", "--", "python", "/work/code/train.py"], s.env);
  assert.equal(ckpt.status, 0, ckpt.stderr);
  const ckptScript = readdirSync(path.join(trainJob, "logs")).find((file) => file.endsWith(".sbatch"));
  const ckptBody = readFileSync(path.join(trainJob, "logs", ckptScript), "utf8");
  assert.match(ckptBody, /trap .*scontrol requeue "\$SLURM_JOB_ID".* USR1/);
  assert.match(ckptBody, /apptainer exec .*&\nchild=\$!/);
  assert.match(readFileSync(s.log, "utf8"), /--signal B:USR1@300 --requeue/);
});
```

- [ ] **Step 2: Run them and see them fail.**

Run: `node --test scripts/hpc-skills.test.mjs`
Expected: all 5 FAIL, because `lib.sh` and `hpc-submit.sh` do not exist (`bash: …/hpc-submit.sh: No such file or directory`).

- [ ] **Step 3: Implement.** `doc/hpc/skills/hpc-jobs/scripts/lib.sh`:

```bash
# Shared helpers for the hpc-jobs scripts. Source it: . "$(dirname "$0")/lib.sh"
HPC_JOBS_ROOT="${HPC_JOBS_ROOT:-/data/jobs}"
HPC_REFS_ROOT="${HPC_REFS_ROOT:-/data/refs}"
HPC_IMAGES_ROOT="${HPC_IMAGES_ROOT:-/data/images}"
HPC_JOBCOMP_LOG="${HPC_JOBCOMP_LOG:-/var/log/slurm/jobcomp.log}"

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

iso_in() { date -u -d "@$(( $(date -u +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

# Slurm time limit (MM, MM:SS, HH:MM:SS, D-HH, D-HH:MM, D-HH:MM:SS) -> seconds.
slurm_time_to_seconds() {
  local t="$1" days=0 h=0 m=0 s=0 a b c
  if [[ "$t" == *-* ]]; then
    days="${t%%-*}"; t="${t#*-}"
    IFS=: read -r h m s <<<"$t"
  else
    IFS=: read -r a b c <<<"$t"
    if [[ -n "$c" ]]; then h=$a; m=$b; s=$c
    elif [[ -n "$b" ]]; then m=$a; s=$b
    else m=$a; fi
  fi
  echo $(( 10#${days:-0} * 86400 + 10#${h:-0} * 3600 + 10#${m:-0} * 60 + 10#${s:-0} ))
}

# Value of KEY in a line of space-separated KEY=value pairs.
field() { sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"$2"; }

# One line per job: active jobs from squeue, finished jobs from the job
# completion log (JobCompType=jobcomp/filetxt), otherwise UNKNOWN.
job_line() {
  local id="$1" line
  line=$(squeue -h -j "$id" -o '%i %T elapsed=%M gres=%b reason=%R' 2>/dev/null || true)
  if [[ -n "$line" ]]; then printf '%s\n' "$line"; return 0; fi
  line=$(grep -m1 "JobId=$id " "$HPC_JOBCOMP_LOG" 2>/dev/null || true)
  if [[ -n "$line" ]]; then
    printf '%s %s exit=%s start=%s end=%s tres=%s\n' "$id" "$(field JobState "$line")" \
      "$(field ExitCode "$line")" "$(field StartTime "$line")" "$(field EndTime "$line")" "$(field Tres "$line")"
    return 0
  fi
  printf '%s UNKNOWN not in squeue or %s\n' "$id" "$HPC_JOBCOMP_LOG"
}

api_request() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsS -X "$method" -H "Authorization: Bearer $PAPERCLIP_API_KEY")
  [[ -n "${PAPERCLIP_RUN_ID:-}" ]] && args+=(-H "X-Paperclip-Run-Id: $PAPERCLIP_RUN_ID")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  curl "${args[@]}" "$PAPERCLIP_API_URL$path"
}

# Sets the issue monitor so Paperclip wakes this agent to check its jobs.
# PATCH replaces the whole executionPolicy, so merge into the current one.
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
  body=$(jq -c --argjson m "$monitor" \
    '{executionPolicy: ((.executionPolicy // {}) | .monitor = ((.monitor // {}) + $m))}' <<<"$issue")
  api_request PATCH "/api/issues/$PAPERCLIP_TASK_ID" "$body" \
    | jq -r '"monitor: next check " + (.monitorNextCheckAt // "NOT SET")'
}
```

`doc/hpc/skills/hpc-jobs/scripts/hpc-submit.sh`:

```bash
#!/usr/bin/env bash
# Submits one job to Slurm and schedules the issue monitor. With --image the
# command runs in that Apptainer container; without it, on the host from the
# job directory (for a Nextflow head job, which must reach sbatch itself).
# --checkpoint: Slurm sends USR1 to the batch shell 5 minutes before the time
# limit; the shell forwards it to the job, waits for the checkpoint, requeues.
# Usage: bash scripts/hpc-submit.sh --job DIR [--image SIF] [--gpus 1] [--cpus 16] [--mem 64G]
#          [--time 24:00:00] [--name NAME] [--checkpoint] -- COMMAND...
set -euo pipefail
. "$(dirname "$0")/lib.sh"

job="" image="" gpus=1 cpus=16 mem=64G time=24:00:00 name="" checkpoint=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --job) job="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --checkpoint) checkpoint=1; shift ;;
    --gpus) gpus="$2"; shift 2 ;;
    --cpus) cpus="$2"; shift 2 ;;
    --mem) mem="$2"; shift 2 ;;
    --time) time="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --) shift; break ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ $# -gt 0 ]] || die "missing command after --"
[[ -n "$job" ]] || die "--job is required"
[[ "$gpus" =~ ^[0-9]+$ && "$cpus" =~ ^[0-9]+$ ]] || die "--gpus and --cpus take whole numbers"
job=$(realpath -m "$job")
[[ "$job" == "$HPC_JOBS_ROOT"/* ]] || die "job directory must be under $HPC_JOBS_ROOT"
[[ -z "$image" || -f "$image" ]] || die "image not found: $image"
mkdir -p "$job/logs" "$job/tmp"

command=("$@")
if [[ -n "$image" ]]; then
  nv=()
  [[ "$gpus" -gt 0 ]] && nv=(--nv)
  command=(apptainer exec "${nv[@]}" --containall --workdir "$job/tmp"
    --bind "$job:/work" --bind "$HPC_REFS_ROOT:/refs:ro" "$image" "$@")
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

args=(--job-name "${name:-$(basename "$job")}" --cpus-per-task "$cpus" --mem "$mem" --time "$time"
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
timeout=$(( $(slurm_time_to_seconds "$time") + 1800 ))
[[ $checkpoint -eq 1 ]] && timeout=""
schedule_monitor 15 "slurm job $jobid in $job" "$timeout"
```

- [ ] **Step 4: Run them and see them pass.** Add the script to `package.json` first.

Run: `node --test scripts/hpc-skills.test.mjs`
Expected: 5/5 PASS.

- [ ] **Step 5: Commit.**

```bash
git add doc/hpc/skills/hpc-jobs/scripts scripts/hpc-skills.test.mjs package.json
git commit -m "feat(hpc): hpc-submit with monitor scheduling and a fake-Slurm test harness"
```

---

### Task 3: `hpc-status.sh`, `hpc-diagnose.sh` and `hpc-report-gpu-hours.sh`

**Files:**
- Create: the three scripts in `doc/hpc/skills/hpc-jobs/scripts/`
- Modify: `scripts/hpc-skills.test.mjs` (add tests)

**Interfaces:**
- Consumes: `lib.sh` (`die`, `field`, `job_line`, `api_request`, `schedule_monitor`), and the harness (`sandbox`, `run`, `apiEnv`, `ISSUE`) from Task 2.

- [ ] **Step 1: Write the failing tests.** Append to `scripts/hpc-skills.test.mjs`:

```js
const DONE_LINE =
  "JobId=4100 UserId=paperclip(1001) Name=done JobState=COMPLETED Partition=all StartTime=2026-09-26T08:00:00 EndTime=2026-09-26T10:00:00 NodeList=hpc1 Tres=cpu=16,mem=64G,node=1,gres/gpu=1 ExitCode=0:0 DerivedExitCode=0:0\n";

test("hpc-status reports active and finished jobs and reschedules only while one is active", () => {
  const s = sandbox();
  writeFileSync(s.env.HPC_JOBCOMP_LOG, DONE_LINE);

  const active = run(path.join(jobsScripts, "hpc-status.sh"), ["--next-check", "30", "4242", "4100", "9999"], {
    ...s.env,
    ...apiEnv,
    FAKE_ISSUE_JSON: ISSUE,
    FAKE_SQUEUE: "4242 RUNNING elapsed=1:02:03 gres=gres/gpu:1 reason=None",
  });

  assert.equal(active.status, 0, active.stderr);
  assert.match(active.stdout, /^4242 RUNNING elapsed=1:02:03/m);
  assert.match(
    active.stdout,
    /^4100 COMPLETED exit=0:0 start=2026-09-26T08:00:00 end=2026-09-26T10:00:00 tres=cpu=16,mem=64G,node=1,gres\/gpu=1$/m,
  );
  assert.match(active.stdout, /^9999 UNKNOWN/m);
  assert.match(readFileSync(s.log, "utf8"), /^PATCH /m);

  writeFileSync(s.log, "");
  const done = run(path.join(jobsScripts, "hpc-status.sh"), ["4100"], { ...s.env, ...apiEnv, FAKE_ISSUE_JSON: ISSUE });
  assert.equal(done.status, 0, done.stderr);
  assert.doesNotMatch(readFileSync(s.log, "utf8"), /PATCH/);
});

test("hpc-diagnose maps out-of-memory and CUDA arch failures to fixes", () => {
  const s = sandbox();
  const job = path.join(s.env.HPC_JOBS_ROOT, "ISS-2", "fit");
  mkdirSync(path.join(job, "logs"), { recursive: true });
  writeFileSync(
    path.join(job, "logs", "4300.out"),
    "RuntimeError: CUDA error: no kernel image is available for execution on the device\n",
  );
  writeFileSync(
    s.env.HPC_JOBCOMP_LOG,
    "JobId=4300 JobState=OUT_OF_MEMORY StartTime=2026-09-26T08:00:00 EndTime=2026-09-26T08:05:00 Tres=cpu=16,gres/gpu=1 ExitCode=0:125\n",
  );

  const r = run(path.join(jobsScripts, "hpc-diagnose.sh"), ["4300", job], s.env);

  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /cause: the job used more memory than --mem/);
  assert.match(r.stdout, /cause: the image's PyTorch\/CUDA build does not support this GPU/);
});

test("hpc-report-gpu-hours posts one cost event per job", () => {
  const s = sandbox();
  const job = path.join(s.env.HPC_JOBS_ROOT, "ISS-3", "train");
  mkdirSync(path.join(job, "logs"), { recursive: true });
  writeFileSync(
    s.env.HPC_JOBCOMP_LOG,
    "JobId=4400 JobState=COMPLETED StartTime=2026-09-26T08:00:00 EndTime=2026-09-26T10:00:00 Tres=cpu=16,mem=64G,node=1,gres/gpu=2 ExitCode=0:0\n",
  );
  const env = { ...s.env, ...apiEnv, HPC_GPU_HOUR_CENTS: "150" };

  const first = run(path.join(jobsScripts, "hpc-report-gpu-hours.sh"), ["4400", job], env);
  assert.equal(first.status, 0, first.stderr);
  assert.match(first.stdout, /reported 4\.00 GPU-hours \(600 cents\)/);
  const post = readFileSync(s.log, "utf8").split("\n").find((line) => line.startsWith("POST "));
  const body = JSON.parse(post.slice(post.indexOf("{")));
  assert.equal(body.costCents, 600);
  assert.equal(body.provider, "hpc");
  assert.equal(body.costStatus, "reported");
  assert.equal(body.agentId, apiEnv.PAPERCLIP_AGENT_ID);

  const second = run(path.join(jobsScripts, "hpc-report-gpu-hours.sh"), ["4400", job], env);
  assert.match(second.stdout, /already reported/);
  const posts = readFileSync(s.log, "utf8").split("\n").filter((line) => line.startsWith("POST "));
  assert.equal(posts.length, 1);
});
```

- [ ] **Step 2: Run them and see them fail.**

Run: `node --test scripts/hpc-skills.test.mjs`
Expected: the 3 new tests FAIL (`No such file or directory`); the Task 2 tests PASS.

- [ ] **Step 3: Implement.** `hpc-status.sh`:

```bash
#!/usr/bin/env bash
# One line per job. While any job is queued or running, reschedules the issue monitor.
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
    PENDING | RUNNING | CONFIGURING | COMPLETING | SUSPENDED | REQUEUED) active=1 ;;
  esac
done
if [[ $active -eq 1 ]]; then schedule_monitor "$next" "slurm jobs $*"; fi
```

`hpc-diagnose.sh`:

```bash
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
```

`hpc-report-gpu-hours.sh`:

```bash
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
```

- [ ] **Step 4: Run them and see them pass.**

Run: `node --test scripts/hpc-skills.test.mjs`
Expected: 8/8 PASS.

- [ ] **Step 5: Commit.**

```bash
git add doc/hpc/skills/hpc-jobs/scripts scripts/hpc-skills.test.mjs
git commit -m "feat(hpc): hpc-status, hpc-diagnose and hpc-report-gpu-hours"
```

---

### Task 4: `hpc-doctor.sh`

**Files:**
- Create: `doc/hpc/skills/hpc-jobs/scripts/hpc-doctor.sh`
- Modify: `scripts/hpc-skills.test.mjs`

**Interfaces:** Consumes the harness from Task 2 and `lib.sh` (paths).

- [ ] **Step 1: Write the failing test.** Append:

```js
test("hpc-doctor passes on a ready box and fails when podman is not rootless", () => {
  const s = sandbox();
  const credential = path.join(s.root, "gcp.json");
  writeFileSync(credential, "{}", { mode: 0o600 });

  const ok = run(path.join(jobsScripts, "hpc-doctor.sh"), [], {
    ...s.env,
    NXF_VER: "25.04.6",
    GOOGLE_APPLICATION_CREDENTIALS: credential,
  });
  assert.equal(ok.status, 0, ok.stdout + ok.stderr);
  assert.match(ok.stdout, /^PASS podman-rootless/m);
  assert.match(ok.stdout, /^PASS gcp-credentials/m);
  assert.match(ok.stdout, /all checks passed/);

  const bad = run(path.join(jobsScripts, "hpc-doctor.sh"), [], {
    ...s.env,
    NXF_VER: "25.04.6",
    FAKE_PODMAN_INFO: "false overlay",
  });
  assert.equal(bad.status, 1);
  assert.match(bad.stdout, /^FAIL podman-rootless/m);
});
```

- [ ] **Step 2: Run it and see it fail.**

Run: `node --test scripts/hpc-skills.test.mjs`
Expected: the new test FAILS (`No such file or directory`).

- [ ] **Step 3: Implement** `hpc-doctor.sh`:

```bash
#!/usr/bin/env bash
# Checks that this box is ready for HPC agents. Prints PASS/FAIL lines; exits 1 on any FAIL.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

fails=0
check() {
  local name="$1" out
  shift
  if out=$("$@" 2>&1); then
    printf 'PASS %s %s\n' "$name" "$(head -n1 <<<"$out")"
  else
    printf 'FAIL %s %s\n' "$name" "$(head -n1 <<<"$out")"
    fails=$((fails + 1))
  fi
}

check slurm-gpu bash -c 'sinfo -h -o "%G" | grep gpu'
check nvidia-driver nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader
check apptainer apptainer --version
check podman-rootless bash -c 'test "$(podman info --format "{{.Host.Security.Rootless}} {{.Store.GraphDriverName}}")" = "true overlay"'
check nextflow bash -c '[ -n "${NXF_VER:-}" ] && nextflow -version | grep -o "version [0-9.]*"'
check jobs-dir test -w "$HPC_JOBS_ROOT"
check refs-dir test -r "$HPC_REFS_ROOT"
check images-dir test -w "$HPC_IMAGES_ROOT"
for tool in node git tar curl jq claude; do check "tool-$tool" command -v "$tool"; done
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  check gcp-credentials bash -c '[ "$(stat -c %a "$GOOGLE_APPLICATION_CREDENTIALS")" = 600 ] && echo "mode 600"'
fi
if [[ $fails -gt 0 ]]; then printf '%s check(s) failed\n' "$fails"; exit 1; fi
printf 'all checks passed\n'
```

- [ ] **Step 4: Run it and see it pass.**

Run: `node --test scripts/hpc-skills.test.mjs`
Expected: 9/9 PASS.

- [ ] **Step 5: Commit.**

```bash
git add doc/hpc/skills/hpc-jobs/scripts/hpc-doctor.sh scripts/hpc-skills.test.mjs
git commit -m "feat(hpc): hpc-doctor readiness checks"
```

---

### Task 5: `hpc-ml-images` skill and `hpc-build-image.sh`

**Files:**
- Create: `doc/hpc/skills/hpc-ml-images/SKILL.md`, `doc/hpc/skills/hpc-ml-images/scripts/hpc-build-image.sh`
- Modify: `scripts/hpc-skills.test.mjs`

**Interfaces:** Consumes the harness. The script is self-contained, because skills cannot source each other's files.

- [ ] **Step 1: Write the failing test.** Append:

```js
test("hpc-build-image stores a sha-named sif and rejects bad names", () => {
  const s = sandbox();
  const context = path.join(s.root, "ctx");
  mkdirSync(context);
  writeFileSync(path.join(context, "Dockerfile"), "FROM scratch\n");

  const r = run(path.join(imagesScripts, "hpc-build-image.sh"), ["torch", "2.8-cu128", context], s.env);

  assert.equal(r.status, 0, r.stderr);
  const built = r.stdout.match(/^image: (.+\/torch\/2\.8-cu128-[0-9a-f]{12}\.sif)$/m);
  assert.ok(built, r.stdout);
  assert.ok(existsSync(built[1]));
  assert.match(readFileSync(s.log, "utf8"), /podman build -t localhost\/torch:2\.8-cu128/);

  const bad = run(path.join(imagesScripts, "hpc-build-image.sh"), ["Bad Name", "x", context], s.env);
  assert.equal(bad.status, 2);
});
```

- [ ] **Step 2: Run it and see it fail.**

Run: `node --test scripts/hpc-skills.test.mjs`
Expected: the new test FAILS (`No such file or directory`).

- [ ] **Step 3: Implement.** `hpc-build-image.sh`:

```bash
#!/usr/bin/env bash
# Builds a Dockerfile with rootless Podman and stores it as a pinned Apptainer image.
# Usage: bash scripts/hpc-build-image.sh NAME TAG CONTEXT_DIR
set -euo pipefail
HPC_IMAGES_ROOT="${HPC_IMAGES_ROOT:-/data/images}"
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

[[ $# -eq 3 ]] || die "usage: hpc-build-image.sh NAME TAG CONTEXT_DIR"
name="$1" tag="$2" context="$3"
[[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ && "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "name (lowercase) and tag may use letters, digits, '.', '_' and '-'"
[[ -f "$context/Dockerfile" ]] || die "no Dockerfile in $context"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
podman build -t "localhost/$name:$tag" "$context"
podman save -o "$tmp/image.tar" "localhost/$name:$tag"
apptainer build "$tmp/image.sif" "docker-archive:$tmp/image.tar"
sha=$(sha256sum "$tmp/image.sif" | cut -c1-12)
dest="$HPC_IMAGES_ROOT/$name/$tag-$sha.sif"
mkdir -p "$(dirname "$dest")"
mv "$tmp/image.sif" "$dest"
printf 'image: %s\n' "$dest"
apptainer inspect --labels "$dest" || true
```

`doc/hpc/skills/hpc-ml-images/SKILL.md`:

````markdown
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

Submit a short test job with the hpc-jobs skill:

```bash
bash scripts/hpc-submit.sh --job /data/jobs/<issue>/image-check --image <sif> --time 10 -- python -c "import torch; print(torch.cuda.get_arch_list(), torch.cuda.is_available())"
```

The arch list must include the GPU's `sm_XY`. Put the image path, its labels and the check result in an issue comment.
````

- [ ] **Step 4: Run it and see it pass.**

Run: `node --test scripts/hpc-skills.test.mjs`
Expected: 10/10 PASS.

- [ ] **Step 5: Commit.**

```bash
git add doc/hpc/skills/hpc-ml-images scripts/hpc-skills.test.mjs
git commit -m "feat(hpc): hpc-ml-images skill with a pinned-image build script"
```

---

### Task 6: `hpc-jobs` and `hpc-nf-core` skill text

**Files:**
- Create: `doc/hpc/skills/hpc-jobs/SKILL.md`, `doc/hpc/skills/hpc-nf-core/SKILL.md`
- Modify: `server/src/__tests__/company-portability.test.ts` (extend the Task 1 describe block)

**Interfaces:** Consumes `previewPackage()` from Task 1.

- [ ] **Step 1: Write the failing test.** Add inside `describe("doc/hpc company package", ...)`:

```ts
  it("ships the three skills with the hpc-jobs and hpc-ml-images scripts", async () => {
    const preview = await previewPackage();
    const skills = Object.fromEntries(preview.manifest.skills.map((skill) => [skill.slug, skill]));

    expect(Object.keys(skills).sort()).toEqual(["hpc-jobs", "hpc-ml-images", "hpc-nf-core"]);
    const scripts = (slug: string) =>
      skills[slug].fileInventory
        .filter((file) => file.kind === "script")
        .map((file) => path.posix.basename(file.path))
        .sort();
    expect(scripts("hpc-jobs")).toEqual([
      "hpc-diagnose.sh",
      "hpc-doctor.sh",
      "hpc-report-gpu-hours.sh",
      "hpc-status.sh",
      "hpc-submit.sh",
      "lib.sh",
    ]);
    expect(scripts("hpc-ml-images")).toEqual(["hpc-build-image.sh"]);
    expect(preview.errors).toEqual([]);
  });
```

- [ ] **Step 2: Run it and see it fail.**

Run: `npx vitest run server/src/__tests__/company-portability.test.ts -t "doc/hpc company package"`
Expected: FAIL. The skill list lacks `hpc-jobs` and `hpc-nf-core`, because their `SKILL.md` files do not exist yet.

- [ ] **Step 3: Write the skills.** `doc/hpc/skills/hpc-jobs/SKILL.md`:

````markdown
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

## Rules

- **Where data goes.** Each job lives in `/data/jobs/<issue>/<job>/`, with `code/`, `inputs/`, `outputs/`, `logs/`, `work/` and `tmp/`.
  - Never put data, outputs or a Nextflow `work/` directory in your Paperclip workspace. The workspace is copied back to the Paperclip server's memory after every run.
  - Reference data in `/data/refs` is read-only.
- **Images.** Use a pinned `.sif` path from `/data/images/<name>/<tag>-<sha12>.sif` (see the hpc-ml-images skill).
- **Limits.** The defaults are 16 CPUs, 64 GB, 1 GPU and 24 h.
  - A job that needs more than 24 h or more than 1 GPU needs board approval first. Use the Paperclip skill's board-approval flow, with this issue in `issueIds`, and wait for the answer.
- **Before running a new box for the first time,** run `bash scripts/hpc-doctor.sh`. Stop and tell the board about any FAIL line.

## Submit a container job

```bash
bash scripts/hpc-submit.sh --job /data/jobs/<issue>/<job> --image <sif> [--gpus 1] [--cpus 16] [--mem 64G] [--time 24:00:00] -- python /work/code/train.py
```

- **Inside the container:** the job directory is `/work`, and reference data is `/refs`. The container starts with a clean environment, so keep configuration in files under `/work`.
- **Without `--image`:** the command runs on the host from the job directory. Use this only for a Nextflow head job (see the hpc-nf-core skill).
- **What the script does:**
  - checks the job with `sbatch --test-only`;
  - writes the batch script to `logs/submit-<time>.sbatch`;
  - submits it;
  - sets the issue monitor, with the first check in 15 minutes and a timeout of the job's `--time` plus 30 minutes.
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
````

`doc/hpc/skills/hpc-nf-core/SKILL.md`:

````markdown
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

## Run a pipeline

1. Create `/data/jobs/<issue>/<run>/`, and write the samplesheet and any params file there.
2. Pin the release. Find it on nf-co.re and never run an unpinned pipeline.
3. Submit the Nextflow head job with the hpc-jobs skill, so it survives your heartbeat:

```bash
bash scripts/hpc-submit.sh --job /data/jobs/<issue>/<run> --gpus 0 --cpus 2 --mem 8G --time 3-00:00:00 -- \
  nextflow run nf-core/<name> -r <release> -profile apptainer -c /etc/paperclip-hpc/nextflow.config \
  --input samplesheet.csv --outdir outputs -work-dir work -resume -with-trace -with-report
```

There is no `--image`: the head job runs on the host from the run directory, because it must call `sbatch` itself. It needs no GPU. Processes that need one get it from the `gpu` label in the config.

## Check and finish

- Use the hpc-jobs skill's monitor loop (`hpc-status.sh`) for the head job.
- From the run directory, `nextflow log` lists runs, and `nextflow log last -f name,status,exit,duration` shows the tasks.
- When the run finishes:
  - put the MultiQC report (`outputs/multiqc/multiqc_report.html`) on the issue as an artifact, generated with `--flat` if it is over 10 MB;
  - record the pipeline release and params in the `hpc-jobs` document.

## Failures

- Run `bash scripts/hpc-diagnose.sh <jobid> /data/jobs/<issue>/<run>`. For a failed process, read `.command.err` in the work directory it names.
- Fix the input or the params, then resubmit the same command. `-resume` reuses finished tasks.

## Clean up

After the results are recorded, free the space: `nextflow clean -before <run-name> -f` from the run directory.
````

- [ ] **Step 4: Run it and see it pass.**

Run: `npx vitest run server/src/__tests__/company-portability.test.ts -t "doc/hpc company package"`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit.**

```bash
git add doc/hpc/skills server/src/__tests__/company-portability.test.ts
git commit -m "feat(hpc): hpc-jobs and hpc-nf-core skills"
```

---

### Task 7: Agents, routines and package settings

**Files:**
- Create: `doc/hpc/agents/hpc-pipeline-engineer/AGENTS.md`, `doc/hpc/agents/ml-environment-engineer/AGENTS.md`, `doc/hpc/tasks/hpc-daily-digest/TASK.md`, `doc/hpc/tasks/hpc-weekly-maintenance/TASK.md`
- Modify: `doc/hpc/.paperclip.yaml`, `server/src/__tests__/company-portability.test.ts`

**Interfaces:** Consumes `previewPackage()`. The skill slugs come from Tasks 5–6.

- [ ] **Step 1: Write the failing test.** Add inside the describe block:

```ts
  it("defines the two agents and two routines with the settings the spec requires", async () => {
    const preview = await previewPackage();
    const agents = Object.fromEntries(preview.manifest.agents.map((agent) => [agent.slug, agent]));

    expect(Object.keys(agents).sort()).toEqual(["hpc-pipeline-engineer", "ml-environment-engineer"]);
    for (const agent of Object.values(agents)) {
      expect(agent.role).toBe("devops");
      expect(agent.adapterType).toBe("claude_local");
      expect(agent.adapterConfig).toMatchObject({ engine: "cli" });
      expect(agent.runtimeConfig).toMatchObject({ heartbeat: { maxDailyRuns: 48 } });
    }
    expect(agents["hpc-pipeline-engineer"].skills.sort()).toEqual(["hpc-jobs", "hpc-nf-core"]);
    expect(agents["ml-environment-engineer"].skills.sort()).toEqual(["hpc-jobs", "hpc-ml-images"]);
    expect(preview.manifest.projects[0].leadAgentSlug).toBe("hpc-pipeline-engineer");

    const routines = preview.manifest.issues.filter((issue) => issue.recurring);
    expect(routines.map((issue) => [issue.slug, issue.assigneeAgentSlug, issue.projectSlug]).sort()).toEqual([
      ["hpc-daily-digest", "hpc-pipeline-engineer", "hpc"],
      ["hpc-weekly-maintenance", "ml-environment-engineer", "hpc"],
    ]);
    const trigger = (slug: string) => routines.find((issue) => issue.slug === slug)?.routine?.triggers[0];
    expect(trigger("hpc-daily-digest")).toMatchObject({ kind: "schedule", cronExpression: "0 13 * * *", timezone: "UTC" });
    expect(trigger("hpc-weekly-maintenance")).toMatchObject({ kind: "schedule", cronExpression: "0 12 * * 1", timezone: "UTC" });
    expect(preview.errors).toEqual([]);
    expect(preview.warnings).toEqual([]);
  });
```

- [ ] **Step 2: Run it and see it fail.**

Run: `npx vitest run server/src/__tests__/company-portability.test.ts -t "doc/hpc company package"`
Expected: FAIL (no agents).

- [ ] **Step 3: Write the files.** `doc/hpc/agents/hpc-pipeline-engineer/AGENTS.md`:

```markdown
---
name: HPC Pipeline Engineer
slug: hpc-pipeline-engineer
title: HPC Pipeline Engineer
role: devops
reportsTo: null
skills:
  - hpc-jobs
  - hpc-nf-core
---

You run bioinformatics and ML work on the company's on-prem HPC box. You work there through Paperclip's ssh environment, and you hand heavy work to Slurm and Apptainer containers.

- Follow the hpc-jobs skill for every job: job directories, limits, the issue monitor, the `hpc-jobs` document and GPU-hour reports.
- Follow the hpc-nf-core skill for pipelines. Always pin the pipeline release and record it.
- Ask for board approval before any job over 24 hours or over 1 GPU.
- Raw data stays on the box. Put summaries, paths and small reports on the issue, never large outputs.
- When a job fails, run hpc-diagnose, apply the fix, and resubmit. If the cause is the box itself (driver, disk, Slurm), stop and tell the board.
- The daily digest routine is yours. List active and finished jobs, GPU-hours, failures and `/data` use, plus a dry-run cleanup list (`nextflow clean -before <run> -n` for runs whose results are recorded). Post it on the routine's issue.
```

`doc/hpc/agents/ml-environment-engineer/AGENTS.md`:

```markdown
---
name: ML Environment Engineer
slug: ml-environment-engineer
title: ML Environment Engineer
role: devops
reportsTo: null
skills:
  - hpc-jobs
  - hpc-ml-images
---

You keep the ML container images on the company's on-prem HPC box current and working. You work there through Paperclip's ssh environment.

- Follow the hpc-ml-images skill for every image: a Dockerfile with a pinned base and version labels, a rootless Podman build, and a pinned `.sif`.
- Before any CUDA or PyTorch change, check the host driver and the GPU's compute capability. Prove the new image on the GPU with a short job before anyone uses it.
- Never delete an image that a recorded job used. Old images move to `/data/images/<name>/archive/`.
- The weekly maintenance routine is yours:
  - run `bash scripts/hpc-doctor.sh`;
  - run a one-GPU test job with the newest image;
  - clean caches with `apptainer cache clean -D 30 -f` and `podman system prune -f`;
  - post the results on the routine's issue.

  If the doctor shows a FAIL or the driver changed, tell the board.
```

`doc/hpc/tasks/hpc-daily-digest/TASK.md`:

```markdown
---
name: HPC daily digest
slug: hpc-daily-digest
project: hpc
assignee: hpc-pipeline-engineer
recurring: true
---

Post the daily HPC digest: active and finished jobs, GPU-hours, failures and their causes, `/data` use (`df -h /data`), and a dry-run cleanup list.
```

`doc/hpc/tasks/hpc-weekly-maintenance/TASK.md`:

```markdown
---
name: HPC weekly maintenance
slug: hpc-weekly-maintenance
project: hpc
assignee: ml-environment-engineer
recurring: true
---

Run the weekly HPC check: `hpc-doctor.sh`, a one-GPU test job with the newest image, and cache cleanup. Report any FAIL or driver change to the board.
```

Replace `doc/hpc/.paperclip.yaml` with:

```yaml
schema: paperclip/v1
schemaVersion: 7
agents:
  hpc-pipeline-engineer:
    adapter:
      type: claude_local
      config:
        engine: cli
    runtime:
      heartbeat:
        enabled: false
        maxDailyRuns: 48
  ml-environment-engineer:
    adapter:
      type: claude_local
      config:
        engine: cli
    runtime:
      heartbeat:
        enabled: false
        maxDailyRuns: 48
projects:
  hpc:
    leadAgentSlug: hpc-pipeline-engineer
routines:
  hpc-daily-digest:
    concurrencyPolicy: skip_if_active
    triggers:
      - kind: schedule
        cronExpression: "0 13 * * *"
        timezone: UTC
  hpc-weekly-maintenance:
    concurrencyPolicy: skip_if_active
    triggers:
      - kind: schedule
        cronExpression: "0 12 * * 1"
        timezone: UTC
```

- [ ] **Step 4: Run it and see it pass.**

Run: `npx vitest run server/src/__tests__/company-portability.test.ts -t "doc/hpc company package"`
Expected: PASS (3 tests). If a value fails to parse, the hand-written YAML parser skipped a line: check the 2-space nesting first.

- [ ] **Step 5: Commit.**

```bash
git add doc/hpc server/src/__tests__/company-portability.test.ts
git commit -m "feat(hpc): expert agents, routines and package settings"
```

---

### Task 8: Setup guide

**Files:**
- Create: `docs/deploy/hpc-agents.md`
- Modify: `docs/docs.json` (add `deploy/hpc-agents` after `deploy/gcp-cloud-run` in the navigation), `docs/deploy/overview.md` (add a link next to the Cloud Run link)

- [ ] **Step 1: Write the guide.** `docs/deploy/hpc-agents.md`:

````markdown
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

## 2. Connect Paperclip

1. Route the Cloud Run VPC to the site (HA VPN or Interconnect). Allow TCP 22 from the Cloud Run subnet only.
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
````

In `docs/docs.json`, add `"deploy/hpc-agents"` right after `"deploy/gcp-cloud-run"`. In `docs/deploy/overview.md`, after the Cloud Run link line, add:

```markdown
- [HPC Agents](hpc-agents.md): run expert agents on on-prem HPC boxes over the ssh environment.
```

- [ ] **Step 2: Check the docs JSON.**

Run: `node -e "JSON.parse(require('fs').readFileSync('docs/docs.json','utf8'))" && grep -n "deploy/hpc-agents" docs/docs.json`
Expected: no error, and one match.

- [ ] **Step 3: Commit.**

```bash
git add docs/deploy/hpc-agents.md docs/docs.json docs/deploy/overview.md
git commit -m "docs(hpc): setup guide for HPC agents"
```

---

### Task 9: Verify and open the PR

- [ ] **Step 1: Run the package and helper tests.**

Run: `node --test scripts/hpc-skills.test.mjs && npx vitest run server/src/__tests__/company-portability.test.ts`
Expected: 10/10 helper tests PASS, and the whole portability file PASSES.

- [ ] **Step 2: Lint the scripts.**

Run: `shellcheck doc/hpc/skills/*/scripts/*.sh`
Expected: no findings. If `shellcheck` is missing, say so in the PR.

- [ ] **Step 3: Open the PR.** Use the PR template (Simplified Technical English, `Refs #5`, Model Used). Run `/ponytail:ponytail-review`, apply the cuts, and have `gabenavarro` merge through the API (see `pr-workflow`).

## Self-review record

- **Spec coverage:**
  - Part 4 (conventions): Task 6 skills. Part 5 (skills, agents): Tasks 5–7.
  - Part 6 (QoL):
    - helper scripts: Tasks 2–5
    - job record and GPU-hours: Tasks 3 and 6
    - routines: Task 7
    - one-command setup: Tasks 7–8
  - Parts 2–3 (connection, runbook): Task 8 guide.
  - Part 1: Plan A.
- **Type consistency:**
  - `lib.sh` function names (`job_line`, `field`, `schedule_monitor`, `api_request`, `slurm_time_to_seconds`, `iso_in`, `die`) match across Tasks 2–4.
  - The harness names (`sandbox`, `run`, `apiEnv`, `ISSUE`, `jobsScripts`, `imagesScripts`) match across Tasks 2–5.
  - `previewPackage` is shared by Tasks 1, 6 and 7.
- **Known ceiling:** `hpc-report-gpu-hours.sh` reads times from the completion log in the box's local time zone, so start and end use the same zone.
