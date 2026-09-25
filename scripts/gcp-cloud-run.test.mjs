// Tests for scripts/gcp-cloud-run.sh. A stub `gcloud` on PATH records every
// call; `--dry-run` prints mutating commands instead of running them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = path.join(repoRoot, "scripts", "gcp-cloud-run.sh");

const STUB_GCLOUD = `#!/usr/bin/env bash
printf '%s|%s\\n' "\${CLOUDSDK_CORE_DISABLE_FILE_LOGGING:-}" "$*" >> "$GCLOUD_LOG"
case "$*" in
  "config get-value account"*) [ -n "\${STUB_NO_ACCOUNT:-}" ] || echo "owner@example.com" ;;
  "projects list"*) if [ -n "\${STUB_EXISTING:-}" ]; then echo "pc-existing"; fi ;;
  "run services describe"*) echo "us-central1-docker.pkg.dev/pc-existing/webapps/paperclip:test" ;;
  "run jobs logs read"*)
    n=$(cat "$GCLOUD_LOG.reads" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$GCLOUD_LOG.reads"
    if [ "$n" -ge 2 ]; then echo "https://paperclip-123456789012.us-central1.run.app/invite/pcp_bootstrap_0123456789abcdef0123456789abcdef0123456789abcdef"; else echo "Container started"; fi ;;
  "billing accounts list"*) echo "billingAccounts/000000-AAAAAA-BBBBBB" ;;
  "builds get-default-service-account"*) echo "123456789012-compute@developer.gserviceaccount.com" ;;
  "projects describe"*)
    if [ -n "\${STUB_EXISTING:-}" ]; then echo "123456789012"; exit 0; fi
    # Resource Manager answers 403, not 404, for a project that does not exist.
    echo "ERROR: (gcloud.projects.describe) [owner@example.com] does not have permission to access projects instance [pc-new-project] (or it may not exist): The caller does not have permission" >&2; exit 1 ;;
  "billing projects describe"*)
    if [ -n "\${STUB_EXISTING:-}" ]; then echo "ERROR: PERMISSION_DENIED: Cloud Billing API has not been used" >&2; exit 1; fi
    echo "ERROR: (gcloud) NOT_FOUND: The resource was not found." >&2; exit 1 ;;
  "sql users describe"*) echo "ERROR: (gcloud.sql.users.describe) HTTPError 404: Not Found." >&2; exit 1 ;;
  "artifacts docker images describe"*)
    if [ -n "\${STUB_IMAGE_EXISTS:-}" ]; then echo "image_summary: {}"; exit 0; fi
    echo "ERROR: (gcloud) NOT_FOUND: image not found" >&2; exit 1 ;;
  *" describe "*|*" list"*|"projects describe"*)
    echo "ERROR: (gcloud) NOT_FOUND: The resource was not found." >&2
    exit 1 ;;
  *) exit 0 ;;
esac
`;

function setupSandbox(config) {
  const dir = mkdtempSync(path.join(tmpdir(), "gcp-cloud-run-test-"));
  const bin = path.join(dir, "bin");
  spawnSync("mkdir", ["-p", bin]);
  writeFileSync(path.join(bin, "gcloud"), STUB_GCLOUD);
  chmodSync(path.join(bin, "gcloud"), 0o755);
  const configFile = path.join(dir, "cloud-run.env");
  writeFileSync(configFile, Object.entries(config).map(([k, v]) => `${k}=${v}`).join("\n") + "\n");
  return { dir, bin, configFile, log: path.join(dir, "gcloud.log") };
}

function runScript(sandbox, args, extraEnv = {}) {
  writeFileSync(sandbox.log, "");
  const result = spawnSync("bash", [script, ...args, "--config", sandbox.configFile], {
    cwd: repoRoot,
    encoding: "utf8",
    input: "",
    env: {
      ...process.env,
      PATH: `${sandbox.bin}${path.delimiter}${process.env.PATH}`,
      GCLOUD_LOG: sandbox.log,
      ...extraEnv,
    },
  });
  return { ...result, calls: readFileSync(sandbox.log, "utf8") };
}

const EXISTING = {
  PROJECT: "pc-existing",
  PROJECT_NUMBER: "123456789012",
  REGION: "us-central1",
  SERVICE: "paperclip",
  AR_REPO: "webapps",
  IMAGE_TAG: "test",
  RUNTIME_SA: "runtime@pc-existing.iam.gserviceaccount.com",
  NETWORK: "default",
  SUBNET: "default",
  BUCKET: "pc-existing-paperclip",
  GOOGLE_AUTH: "yes",
  ALLOWED_DOMAINS: "example.com",
  GEMINI_MODEL: "gemini-3.8-flash",
  CPU: "1",
  MEMORY: "2Gi",
  MIN_INSTANCES: "1",
};

test("the script parses", () => {
  const result = spawnSync("bash", ["-n", script], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
});

test("setup on a new project plans every resource, in order, without printing secrets", () => {
  const sandbox = setupSandbox({
    PROJECT: "pc-new-project",
    REGION: "us-central1",
    IMAGE_TAG: "test",
    ALLOWED_EMAILS: "owner@example.com",
  });
  const result = runScript(sandbox, ["setup", "--dry-run", "--yes"]);
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);

  const expectedOrder = [
    /gcloud projects create pc-new-project/,
    /gcloud billing projects link pc-new-project --billing-account=000000-AAAAAA-BBBBBB/,
    /gcloud services enable .*run\.googleapis\.com/,
    /gcloud artifacts repositories create paperclip/,
    /gcloud projects add-iam-policy-binding pc-new-project --member=serviceAccount:123456789012-compute@developer\.gserviceaccount\.com --role=roles\/cloudbuild\.builds\.builder/,
    /gcloud iam service-accounts create paperclip-runtime/,
    /gcloud compute networks create paperclip/,
    /gcloud compute addresses create paperclip-psa-range --global --purpose=VPC_PEERING/,
    /gcloud services vpc-peerings connect/,
    /gcloud sql instances create paperclip-db .*--no-assign-ip/,
    /gcloud storage buckets create gs:\/\/pc-new-project-paperclip/,
    /gcloud secrets create paperclip-secrets-master-key/,
    /gcloud builds submit/,
    /gcloud run deploy paperclip/,
    /gcloud run jobs deploy paperclip-bootstrap-admin/,
  ];
  let cursor = 0;
  for (const pattern of expectedOrder) {
    const rest = result.stdout.slice(cursor);
    const match = rest.match(pattern);
    assert.ok(match, `missing (or out of order): ${pattern}`);
    cursor += (match.index ?? 0) + match[0].length;
  }

  // Generated values (base64 master key, hex passwords) must never be printed.
  assert.doesNotMatch(result.stdout + result.stderr, /[A-Za-z0-9+/]{43}=/);
  assert.doesNotMatch(result.stdout + result.stderr, /[0-9a-f]{48}/);
});

test("deploy keeps the flags the service depends on", () => {
  const sandbox = setupSandbox(EXISTING);
  const result = runScript(sandbox, ["deploy", "--dry-run"]);
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);

  const deployLine = result.stdout.split("\n").find((line) => line.includes("gcloud run deploy"));
  assert.ok(deployLine, result.stdout);
  for (const flag of [
    "--image=us-central1-docker.pkg.dev/pc-existing/webapps/paperclip:test",
    "--service-account=runtime@pc-existing.iam.gserviceaccount.com",
    "--execution-environment=gen2",
    "--no-cpu-throttling",
    "--min-instances=1",
    "--max-instances=1",
    "--cpu=1",
    "--memory=2Gi",
    "--network=default",
    "--subnet=default",
    "--vpc-egress=private-ranges-only",
    "--allow-unauthenticated",
    "--clear-volumes",
    "--startup-probe=httpGet.path=/api/health",
  ]) {
    assert.ok(deployLine.includes(flag), `run deploy is missing ${flag}\n${deployLine}`);
  }
  assert.match(deployLine, /only-dir=companies\\?;uid=1000\\?;gid=1000/);
  assert.match(deployLine, /DATABASE_URL=paperclip-database-url:latest/);
  assert.match(deployLine, /PAPERCLIP_AUTH_GOOGLE_CLIENT_SECRET=paperclip-google-oauth-client-secret:latest/);
});

test("deploy builds the committed tree, not the working directory", () => {
  const sandbox = setupSandbox(EXISTING);
  const result = runScript(sandbox, ["deploy", "--dry-run"]);
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  // git archive holds only committed files: no local keys, no .env, and no
  // tracked file dropped by gitignore-style upload filtering.
  assert.match(result.stdout, /\$ git -C \S+ archive --format=tar\.gz --output=\S+source\.tgz HEAD/);
  const submit = result.stdout.split("\n").find((line) => line.includes("gcloud builds submit"));
  assert.ok(submit, result.stdout);
  assert.match(submit, /gcloud builds submit \S+source\.tgz /);
  // --async: a deployer who cannot read build logs can still start and poll the build.
  assert.ok(submit.includes("--async"), submit);
});

test("deploy skips the build when the image for this commit already exists", () => {
  const sandbox = setupSandbox(EXISTING);
  const result = runScript(sandbox, ["deploy", "--dry-run"], { STUB_IMAGE_EXISTS: "1" });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /already built/);
  assert.doesNotMatch(result.stdout, /gcloud builds submit/);
  assert.match(result.stdout, /gcloud run deploy paperclip/);
});

test("without --yes, declining a changing command stops before it runs", () => {
  const sandbox = setupSandbox(EXISTING);
  writeFileSync(sandbox.log, "");
  const result = spawnSync("bash", [script, "deploy", "--config", sandbox.configFile], {
    cwd: repoRoot,
    encoding: "utf8",
    input: "n\n",
    env: { ...process.env, PATH: `${sandbox.bin}${path.delimiter}${process.env.PATH}`, GCLOUD_LOG: sandbox.log },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /stopped before a required step/);
  assert.doesNotMatch(readFileSync(sandbox.log, "utf8"), /builds submit/);
});

test("setup on an existing project keeps going when billing status cannot be read", () => {
  const sandbox = setupSandbox({
    PROJECT: "pc-existing",
    REGION: "us-central1",
    IMAGE_TAG: "test",
    ALLOWED_EMAILS: "owner@example.com",
  });
  const result = runScript(sandbox, ["setup", "--dry-run", "--yes"], { STUB_EXISTING: "1" });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.doesNotMatch(result.stdout, /gcloud projects create/);
  assert.doesNotMatch(result.stdout, /gcloud billing projects link/);
  assert.match(result.stderr, /cannot read the billing status/);
  // "HTTPError 404: Not Found" (Cloud SQL) counts as missing, so the user is created.
  assert.match(result.stdout, /gcloud sql users create paperclip/);
});

test("gcloud never writes this script's commands (with a password flag) to its own log file", () => {
  const sandbox = setupSandbox({ PROJECT: "pc-new-project", REGION: "us-central1", IMAGE_TAG: "test", ALLOWED_EMAILS: "owner@example.com" });
  const result = runScript(sandbox, ["setup", "--dry-run", "--yes"]);
  assert.equal(result.status, 0, result.stderr);
  const lines = result.calls.trim().split("\n");
  assert.ok(lines.length > 5);
  for (const line of lines) assert.ok(line.startsWith("1|"), `file logging not disabled for: ${line}`);
});

test("setup signs in with gcloud auth login when no account is active", () => {
  const sandbox = setupSandbox({ PROJECT: "pc-new-project", REGION: "us-central1", IMAGE_TAG: "test", ALLOWED_EMAILS: "owner@example.com" });
  const result = runScript(sandbox, ["setup", "--dry-run", "--yes"], { STUB_NO_ACCOUNT: "1" });
  assert.equal(result.status, 0, result.stderr);
  // gcloud auth login must be allowed to prompt, although the script turns prompts off elsewhere.
  assert.match(result.stdout, /\$ env CLOUDSDK_CORE_DISABLE_PROMPTS=0 gcloud auth login/);
});

test("bootstrap-admin keeps reading the job logs until the invite appears", () => {
  const sandbox = setupSandbox(EXISTING);
  const result = runScript(sandbox, ["bootstrap-admin", "--yes"]);
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /First-admin invite \(single use, 72 hours\): https:\/\/paperclip-123456789012\.us-central1\.run\.app\/invite\/pcp_bootstrap_[0-9a-f]{48}/);
  // Only this run's entries: a previous run's (now revoked) invite must not match.
  assert.match(result.calls, /run jobs logs read paperclip-bootstrap-admin .*--log-filter=timestamp>=/);
});

test("deploy explains a 403 from the new service as an organization policy on public access", () => {
  const sandbox = setupSandbox(EXISTING);
  writeFileSync(path.join(sandbox.bin, "curl"), `#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; esac; shift; done
[ -n "$out" ] && printf 'Forbidden' > "$out"
printf '403'
`);
  chmodSync(path.join(sandbox.bin, "curl"), 0o755);
  const result = runScript(sandbox, ["deploy", "--yes"], { STUB_IMAGE_EXISTS: "1" });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stderr, /iam\.allowedPolicyMemberDomains/);
});
