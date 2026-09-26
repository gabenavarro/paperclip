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
  assert.match(calls, /sbatch .*--parsable .*--chdir \S+\/ISS-1\/train /, "the job must start in its job directory, not the workspace");
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

test("hpc-submit refuses a job directory outside HPC_JOBS_ROOT and a non-minute --time", () => {
  const s = sandbox();

  const r = run(path.join(jobsScripts, "hpc-submit.sh"), ["--job", s.root, "--image", s.image, "--", "true"], s.env);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /must be under/);

  const job = path.join(s.env.HPC_JOBS_ROOT, "ISS-1", "t");
  mkdirSync(job, { recursive: true });
  const badTime = run(path.join(jobsScripts, "hpc-submit.sh"), ["--job", job, "--time", "24:00:00", "--", "true"], s.env);
  assert.equal(badTime.status, 2);
  assert.match(badTime.stderr, /--time takes minutes/);
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
