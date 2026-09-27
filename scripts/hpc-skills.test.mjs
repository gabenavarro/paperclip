import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, symlinkSync, writeFileSync } from "node:fs";
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
  build) printf 'fake sif\\n' > "$2"; printf 'APPTAINER_TMPDIR=%s\\n' "\${APPTAINER_TMPDIR:-}" >> "$FAKE_LOG" ;;
  inspect) echo "cuda: 12.8" ;;
esac`,
  podman: `printf 'podman %s\\n' "$*" >> "$FAKE_LOG"
case "$1" in
  info) echo "\${FAKE_PODMAN_INFO:-true overlay}" ;;
  save) while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then printf 'tar' > "$2"; fi; shift; done ;;
esac`,
  curl: `printf 'ARGV %s\\n' "$*" >> "$FAKE_LOG"
method=GET; data=""; url=""
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
  assert.ok(body.includes(`--bind ${s.env.HPC_JOBS_ROOT}:${s.env.HPC_JOBS_ROOT}:ro`), "absolute links into other job directories must resolve");
  assert.ok(body.includes(`--bind ${s.env.HPC_REFS_ROOT}:${s.env.HPC_REFS_ROOT}:ro`), "absolute links into the refs must resolve");
  assert.doesNotMatch(calls, /bridge-token/, "the bridge token must stay out of curl's argv");
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
  const buildCalls = readFileSync(s.log, "utf8");
  assert.match(buildCalls, /podman build -t localhost\/torch:2\.8-cu128/);
  assert.ok(buildCalls.includes(`apptainer build ${s.env.HPC_IMAGES_ROOT}/`), "stage the build next to the images, not in /tmp");
  assert.ok(buildCalls.includes(`APPTAINER_TMPDIR=${s.env.HPC_IMAGES_ROOT}/`), buildCalls);

  const bad = run(path.join(imagesScripts, "hpc-build-image.sh"), ["Bad Name", "x", context], s.env);
  assert.equal(bad.status, 2);
});

const REQUEUED_LINE =
  "JobId=5000 JobState=REQUEUED StartTime=2026-09-26T00:00:00 EndTime=2026-09-26T12:00:00 Tres=cpu=16,mem=64G,node=1,gres/gpu=2 ExitCode=0:15\n";
const FINAL_LINE =
  "JobId=5000 JobState=COMPLETED StartTime=2026-09-26T12:10:00 EndTime=2026-09-26T22:10:00 Tres=cpu=16,mem=64G,node=1,gres/gpu=2 ExitCode=0:0\n";

test("a requeued job is read from its last record, and its GPU-hours sum every run", () => {
  const s = sandbox();
  const job = path.join(s.env.HPC_JOBS_ROOT, "ISS-5", "long");
  mkdirSync(path.join(job, "logs"), { recursive: true });
  const env = { ...s.env, ...apiEnv, FAKE_ISSUE_JSON: ISSUE, HPC_GPU_HOUR_CENTS: "100" };

  writeFileSync(s.env.HPC_JOBCOMP_LOG, REQUEUED_LINE);
  const early = run(path.join(jobsScripts, "hpc-report-gpu-hours.sh"), ["5000", job], env);
  assert.equal(early.status, 2);
  assert.match(early.stderr, /requeued/);

  writeFileSync(s.env.HPC_JOBCOMP_LOG, REQUEUED_LINE + FINAL_LINE);
  const status = run(path.join(jobsScripts, "hpc-status.sh"), ["5000"], env);
  assert.equal(status.status, 0, status.stderr);
  assert.match(status.stdout, /^5000 COMPLETED /m);
  assert.doesNotMatch(readFileSync(s.log, "utf8"), /^PATCH /m);

  const report = run(path.join(jobsScripts, "hpc-report-gpu-hours.sh"), ["5000", job], env);
  assert.equal(report.status, 0, report.stderr);
  assert.match(report.stdout, /reported 44\.00 GPU-hours \(4400 cents\)/);
});

test("the monitor keeps its escalation deadline after it has fired", () => {
  const s = sandbox();
  const firedIssue = JSON.stringify({
    id: "issue-1",
    executionPolicy: { mode: "normal", commentRequired: true, stages: [{ type: "review", participants: [] }] },
    executionState: { monitor: { status: "triggered", timeoutAt: "2099-01-01T00:00:00.000Z", kind: "external_service" } },
  });
  const env = { ...s.env, ...apiEnv, FAKE_ISSUE_JSON: firedIssue };
  const deadline = () => {
    const patch = readFileSync(s.log, "utf8").split("\n").findLast((line) => line.startsWith("PATCH "));
    return JSON.parse(patch.slice(patch.indexOf("{"))).executionPolicy.monitor.timeoutAt;
  };

  const status = run(path.join(jobsScripts, "hpc-status.sh"), ["4242"], {
    ...env,
    FAKE_SQUEUE: "4242 RUNNING elapsed=2:00:00 gres=gres/gpu:1 reason=None",
  });
  assert.equal(status.status, 0, status.stderr);
  assert.equal(deadline(), "2099-01-01T00:00:00.000Z");

  const job = path.join(s.env.HPC_JOBS_ROOT, "ISS-1", "second");
  mkdirSync(job, { recursive: true });
  const submit = run(path.join(jobsScripts, "hpc-submit.sh"), ["--job", job, "--gpus", "0", "--", "true"], env);
  assert.equal(submit.status, 0, submit.stderr);
  assert.equal(deadline(), "2099-01-01T00:00:00.000Z", "a second submit keeps the later deadline");
});

test("hpc-status keeps checking a job whose state it cannot read", () => {
  const s = sandbox();

  const r = run(path.join(jobsScripts, "hpc-status.sh"), ["7777"], { ...s.env, ...apiEnv, FAKE_ISSUE_JSON: ISSUE });

  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^7777 UNKNOWN/m);
  assert.match(readFileSync(s.log, "utf8"), /^PATCH /m);
});

test("hpc-submit accepts a jobs root with a trailing slash or behind a symlink", () => {
  const s = sandbox();
  const job = path.join(s.env.HPC_JOBS_ROOT, "ISS-6", "j");
  mkdirSync(job, { recursive: true });

  const slash = run(path.join(jobsScripts, "hpc-submit.sh"), ["--job", job, "--gpus", "0", "--", "true"], {
    ...s.env,
    HPC_JOBS_ROOT: `${s.env.HPC_JOBS_ROOT}/`,
  });
  assert.equal(slash.status, 0, slash.stderr);

  const link = path.join(s.root, "jobs-link");
  symlinkSync(s.env.HPC_JOBS_ROOT, link);
  const viaLink = run(path.join(jobsScripts, "hpc-submit.sh"), ["--job", path.join(link, "ISS-6", "j"), "--gpus", "0", "--", "true"], {
    ...s.env,
    HPC_JOBS_ROOT: link,
  });
  assert.equal(viaLink.status, 0, viaLink.stderr);
});
