# SSH Environment Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Paperclip's `ssh` execution environment fit for long-running agents on a remote HPC box. Reuse one SSH connection, keep env values out of argv, poll the bridge once a second, fix the helper timeouts, allow cost events on the bridge, and delete per-run remote copies.

**Architecture:** All changes are in `packages/adapter-utils` (`ssh.ts`, `server-utils.ts`, `execution-target.ts`, `sandbox-callback-bridge.ts`, `remote-managed-runtime.ts`). OpenSSH does the connection reuse (ControlMaster). Env travels on stdin as `KEY base64(value)` lines that a POSIX `sh` loop reads before `exec`. There are no new dependencies.

**Tech Stack:** TypeScript (Node 24), Vitest 4, OpenSSH client and `sshd` (the env-lab fixture), POSIX `sh`, `base64`.

**Spec:** `doc/plans/2026-09-25-hpc-agents-over-ssh.md`, Part 1 (items 1–6). Issue #5.

## Global Constraints

- Internal systems only. Add no dependency and no external service.
- No secret value in any `ssh` argv. Env values go on stdin (spec Part 1.3).
- Keep the existing login-profile order: `/etc/profile`, `~/.profile`, `~/.bash_profile` or `~/.bashrc`, `~/.zprofile`. User env must win over profile exports.
- Run Vitest from the repo root: `npx vitest run <path> [-t "<name>"]`.
- `pnpm` is not on this machine's PATH; use `npx -y pnpm@9.15.4` if a script needs it. `cargo` is missing, so the server's `typecheck` script fails here. Type-check with `npx tsc --noEmit -p <package dir>` instead.
- The repo is public. Write no internal hostnames, project IDs or IPs in code, tests or commits.
- Branch: `fix/ssh-environment-hardening` from `master`. Only `gabenavarro` merges. Commits end with the Claude Code attribution trailer.

## Review Focus

These are the five input classes the tests below must pin:

1. Env values with `'`, `"`, `$`, backticks, non-ASCII text, embedded newlines, trailing newlines, or an empty value must arrive byte-exact (Task 2, fixture test "delivers env values byte-exact").
2. A command that reads its own stdin, such as an agent prompt, must get it unchanged after the env block, on both the helper path and the agent-spawn path (Task 2, fixture tests "passes the command's own stdin" and "runs a remote child process").
3. The first SSH call must not wait for the backgrounded ControlMaster to release stdio (Task 1, timing assertion).
4. Remote cleanup must never delete anything outside `.paperclip-runtime/runs/<runId>`. Empty or path-like run IDs must be refused (Task 6, unit test).
5. An `execFile` maxBuffer overflow (`killed: true`, `code: "ERR_CHILD_PROCESS_STDIO_MAXBUFFER"`) must not be reported as a timeout (Task 4, unit test).

---

### Task 1: Reuse one SSH connection (ControlMaster)

**Files:**
- Modify: `packages/adapter-utils/src/ssh.ts` (`createSshAuthArgs`, around lines 374–409)
- Test: `packages/adapter-utils/src/ssh-fixture.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces: `createSshAuthArgs` adds the ControlMaster options to every `ssh` call. Its signature is unchanged.

- [ ] **Step 1: Write the failing test.** Add this inside `describe("ssh env-lab fixture", ...)`:

```ts
  it("reuses one SSH connection across commands", async () => {
    const rootDir = await createFixtureRootDir();
    const statePath = path.join(rootDir, "state.json");

    const started = await startSshEnvLabFixtureOrSkip(statePath, "SSH connection reuse test");
    if (!started) return;
    const config = await buildSshEnvLabFixtureConfig(started);
    // Count only the logins our commands cause; the fixture's own readiness
    // check may log in before this point.
    const countLogins = async () =>
      (await readFile(started.sshdLogPath, "utf8")).match(/Accepted publickey/g)?.length ?? 0;
    const loginsBefore = await countLogins();

    const firstStartedAt = Date.now();
    await runSshCommand(config, "true", { timeoutMs: 30_000 });
    // A backgrounded master that kept our stdio pipes open would stall this
    // call until ControlPersist ends (120 s).
    expect(Date.now() - firstStartedAt).toBeLessThan(10_000);
    await runSshCommand(config, "true", { timeoutMs: 30_000 });
    await runSshCommand(config, "true", { timeoutMs: 30_000 });

    expect((await countLogins()) - loginsBefore).toBeLessThanOrEqual(1);
  }, SSH_FIXTURE_TEST_TIMEOUT_MS);
```

- [ ] **Step 2: Run it and see it fail.**

Run: `npx vitest run packages/adapter-utils/src/ssh-fixture.test.ts -t "reuses one SSH connection"`
Expected: FAIL with `expected 3 to be less than or equal to 1` (each call logs in again).

- [ ] **Step 3: Implement.** In `ssh.ts`, add above `createSshAuthArgs`:

```ts
// One private directory per server process for ssh control sockets (mkdtemp
// creates it 0700). `%C` hashes host, port and user, so each target gets one
// master connection that every later command reuses.
let sshControlDirPath: string | undefined;

async function sshControlDir(): Promise<string> {
  sshControlDirPath ??= await fs.mkdtemp(path.join(os.tmpdir(), "pc-ssh-"));
  return sshControlDirPath;
}
```

Then replace the `sshArgs` initializer in `createSshAuthArgs` with:

```ts
  const sshArgs = [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=10",
    "-o",
    `StrictHostKeyChecking=${config.strictHostKeyChecking ? "yes" : "no"}`,
    // Reuse one authenticated connection per target (see sshControlDir), and
    // notice a dead VPN within about a minute instead of TCP's ~2 hours.
    "-o",
    "ControlMaster=auto",
    "-o",
    `ControlPath=${path.join(await sshControlDir(), "%C")}`,
    "-o",
    "ControlPersist=120",
    "-o",
    "ServerAliveInterval=15",
    "-o",
    "ServerAliveCountMax=4",
  ];
```

- [ ] **Step 4: Run it and see it pass.**

Run: `npx vitest run packages/adapter-utils/src/ssh-fixture.test.ts -t "reuses one SSH connection"`
Expected: PASS.

If the timing assertion fails (the first call takes about 120 s), the backgrounded master is holding stdio. Fall back to starting the master explicitly: run `ssh -o ControlMaster=yes -o ControlPersist=120 -MNf <target>` once per control path, and pass `ControlMaster=no` on every call. Re-run the test.

- [ ] **Step 5: Run the whole fixture file** (other tests must still pass with reuse).

Run: `npx vitest run packages/adapter-utils/src/ssh-fixture.test.ts`
Expected: all PASS.

- [ ] **Step 6: Commit.**

```bash
git add packages/adapter-utils/src/ssh.ts packages/adapter-utils/src/ssh-fixture.test.ts
git commit -m "fix(ssh): reuse one SSH connection per target with ControlMaster"
```

---

### Task 2: Send env on stdin, never in argv

**Files:**
- Modify: `packages/adapter-utils/src/ssh.ts` (new `LOGIN_PROFILE_SCRIPT`, `READ_ENV_FROM_STDIN`, `encodeSshEnvStdin`; rewrite parts of `runSshCommand`, `buildSshSpawnTarget` and `createSshCommandManagedRuntimeRunner.execute`)
- Modify: `packages/adapter-utils/src/server-utils.ts` (`SpawnTarget`, `resolveSpawnTarget`, `runChildProcess`)
- Test: `packages/adapter-utils/src/ssh-fixture.test.ts`

**Interfaces:**
- Consumes: `createSshAuthArgs` (Task 1).
- Produces:
  - `encodeSshEnvStdin(env)`: a function local to `ssh.ts`, not exported.
  - `buildSshSpawnTarget(...)` now returns `{ command: string; args: string[]; stdinPrefix: string; cleanup: () => Promise<void> }`
  - `SpawnTarget` gains `stdinPrefix?: string`.

- [ ] **Step 1: Write the failing test.** Add these imports to `ssh-fixture.test.ts`: `import { randomUUID } from "node:crypto";`, `import { runChildProcess } from "./server-utils.js";`, and add `createSshCommandManagedRuntimeRunner` to the `./ssh.js` import list. Then add:

```ts
  it("keeps env values out of the ssh argv and sends them on stdin", async () => {
    const target = await buildSshSpawnTarget({
      spec: {
        host: "ssh.example.test",
        port: 22,
        username: "ssh-user",
        remoteCwd: "/srv/paperclip/workspace",
        remoteWorkspacePath: "/srv/paperclip/workspace",
        privateKey: null,
        knownHosts: null,
        strictHostKeyChecking: true,
      },
      command: "node",
      args: ["--version"],
      env: { PAPERCLIP_API_KEY: "s3cr3t-token-value" },
    });

    expect(target.args.join(" ")).not.toContain("s3cr3t-token-value");
    expect(target.stdinPrefix).toBe(
      `PAPERCLIP_API_KEY ${Buffer.from("s3cr3t-token-value", "utf8").toString("base64")}\n\n`,
    );
    const remoteScript = String(target.args.at(-1) ?? "");
    expect(remoteScript).toContain("base64 -d");
    expect(remoteScript).not.toContain("exec env ");
    await target.cleanup();
  });
```

In the existing test `"builds a remote script that sources login profiles but no nvm"`, replace `expect(remoteScript).toContain("exec env ");` with:

```ts
    expect(remoteScript).toContain("base64 -d");
    // Profiles cannot read stdin, so they cannot eat the env block or the prompt.
    expect(remoteScript).toContain("</dev/null");
```

- [ ] **Step 2: Run the tests and see them fail.**

Run: `npx vitest run packages/adapter-utils/src/ssh-fixture.test.ts -t "argv|login profiles"`
Expected: FAIL. The argv contains `s3cr3t-token-value`, and the script has no `base64 -d` and no `</dev/null`.

- [ ] **Step 3: Add the guard tests.** They pass before and after the change, and pin behavior that must not regress (Review Focus 1–2):

```ts
  it("delivers env values byte-exact without putting them in argv", async () => {
    const rootDir = await createFixtureRootDir();
    const statePath = path.join(rootDir, "state.json");
    const started = await startSshEnvLabFixtureOrSkip(statePath, "SSH env over stdin test");
    if (!started) return;
    const config = await buildSshEnvLabFixtureConfig(started);
    const tricky = "it's \"quoted\" $HOME `x` ü\nline2\n\n";

    const result = await runSshCommand(config, 'printf %s "$TRICKY"; printf "|%s" "$EMPTY"', {
      env: { TRICKY: tricky, EMPTY: "" },
      timeoutMs: 30_000,
    });

    expect(result.stdout).toBe(`${tricky}|`);
  }, SSH_FIXTURE_TEST_TIMEOUT_MS);

  it("passes the command's own stdin after the env block", async () => {
    const rootDir = await createFixtureRootDir();
    const statePath = path.join(rootDir, "state.json");
    const started = await startSshEnvLabFixtureOrSkip(statePath, "SSH env plus stdin test");
    if (!started) return;
    const config = await buildSshEnvLabFixtureConfig(started);

    const result = await runSshCommand(config, 'printf "%s|" "$A"; cat', {
      env: { A: "one" },
      stdin: "payload\nmore\n",
      timeoutMs: 30_000,
    });

    expect(result.stdout).toBe("one|payload\nmore\n");
  }, SSH_FIXTURE_TEST_TIMEOUT_MS);

  it("runs a remote child process with env on stdin before the prompt", async () => {
    const rootDir = await createFixtureRootDir();
    const statePath = path.join(rootDir, "state.json");
    const started = await startSshEnvLabFixtureOrSkip(statePath, "SSH child process env test");
    if (!started) return;
    const config = await buildSshEnvLabFixtureConfig(started);
    const localDir = path.join(rootDir, "local");
    await mkdir(localDir, { recursive: true });

    const result = await runChildProcess(randomUUID(), "sh", ["-c", 'printf "%s|" "$A"; cat'], {
      cwd: localDir,
      env: { A: "one" },
      timeoutSec: 30,
      graceSec: 5,
      onLog: async () => {},
      stdin: "prompt text",
      remoteExecution: { ...config, remoteCwd: started.workspaceDir },
    });

    expect(result.stdout).toBe("one|prompt text");
  }, SSH_FIXTURE_TEST_TIMEOUT_MS);

  it("runs runner shell commands with env from stdin", async () => {
    const rootDir = await createFixtureRootDir();
    const statePath = path.join(rootDir, "state.json");
    const started = await startSshEnvLabFixtureOrSkip(statePath, "SSH runner env test");
    if (!started) return;
    const config = await buildSshEnvLabFixtureConfig(started);
    const runner = createSshCommandManagedRuntimeRunner({
      spec: { ...config, remoteCwd: started.workspaceDir },
    });

    const result = await runner.execute({ command: "sh", args: ["-c", 'printf %s "$K"'], env: { K: "v a l" } });

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toBe("v a l");
  }, SSH_FIXTURE_TEST_TIMEOUT_MS);
```

Run: `npx vitest run packages/adapter-utils/src/ssh-fixture.test.ts -t "byte-exact|own stdin|child process with env|runner shell"`
Expected: PASS (they pass today).

- [ ] **Step 4: Implement in `ssh.ts`.** Add near `shellQuote`:

```ts
// Login profiles run with stdin from /dev/null, so a profile that reads stdin
// cannot eat the env block or the command's own input.
const LOGIN_PROFILE_SCRIPT = [
  'if [ -f /etc/profile ]; then . /etc/profile </dev/null >/dev/null 2>&1 || true; fi',
  'if [ -f "$HOME/.profile" ]; then . "$HOME/.profile" </dev/null >/dev/null 2>&1 || true; fi',
  'if [ -f "$HOME/.bash_profile" ]; then . "$HOME/.bash_profile" </dev/null >/dev/null 2>&1 || true; elif [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc" </dev/null >/dev/null 2>&1 || true; fi',
  'if [ -f "$HOME/.zprofile" ]; then . "$HOME/.zprofile" </dev/null >/dev/null 2>&1 || true; fi',
];

// Env travels on stdin, never in argv: one `KEY base64(value)` line per
// variable, then an empty line. `read` takes a pipe one byte at a time, so the
// command after the loop still gets the rest of stdin unchanged. The `x`
// sentinel keeps trailing newlines that `$(...)` would strip. Exit 97 means a
// value did not decode (for example, no `base64` on the host).
const READ_ENV_FROM_STDIN =
  'while IFS= read -r __pc_l && [ -n "$__pc_l" ]; do __pc_v=$(printf %s "${__pc_l#* }" | base64 -d && printf x) || exit 97; export "${__pc_l%% *}=${__pc_v%x}"; done';

function encodeSshEnvStdin(env: Record<string, string | undefined> | undefined): string {
  const lines = Object.entries(env ?? {}).flatMap(([key, value]) => {
    if (typeof value !== "string") return [];
    if (!isValidShellEnvKey(key)) {
      throw new Error(`Invalid SSH environment variable key: ${key}`);
    }
    return [`${key} ${Buffer.from(value, "utf8").toString("base64")}\n`];
  });
  return lines.length > 0 ? `${lines.join("")}\n` : "";
}
```

Replace the body of `runSshCommand`. Keep the long comment about profiles, and widen `options.env` to `Record<string, string | undefined>` so callers can pass their env as-is:

```ts
  let cleanup: () => Promise<void> = () => Promise.resolve();
  try {
    const envStdin = encodeSshEnvStdin(options.env);
    const auth = await createSshAuthArgs(config);
    cleanup = auth.cleanup;
    const remoteScript = [
      ...LOGIN_PROFILE_SCRIPT,
      ...(envStdin ? [READ_ENV_FROM_STDIN] : []),
      `exec sh -c ${shellQuote(remoteCommand)}`,
    ].join(" && ");
    const sshArgs = [
      ...auth.args,
      "-p",
      String(config.port),
      `${config.username}@${config.host}`,
      `sh -c ${shellQuote(remoteScript)}`,
    ];
    const stdin = envStdin || options.stdin != null ? `${envStdin}${options.stdin ?? ""}` : null;
    return stdin != null
      ? await spawnText("ssh", sshArgs, {
          stdin,
          timeout: options.timeoutMs ?? 15_000,
          maxBuffer: options.maxBuffer ?? 1024 * 128,
        })
      : await execFileText("ssh", sshArgs, {
          timeout: options.timeoutMs ?? 15_000,
          maxBuffer: options.maxBuffer ?? 1024 * 128,
        });
  } finally {
    await cleanup();
  }
```

Replace the body of `buildSshSpawnTarget` and add `stdinPrefix: string` to its return type:

```ts
  const stdinPrefix = encodeSshEnvStdin(input.env);
  const auth = await createSshAuthArgs(input.spec);
  const remoteCommandParts = [shellQuote(input.command), ...input.args.map((arg) => shellQuote(arg))].join(" ");
  const remoteScript = [
    ...LOGIN_PROFILE_SCRIPT,
    ...(stdinPrefix ? [READ_ENV_FROM_STDIN] : []),
    `cd ${shellQuote(input.spec.remoteCwd)}`,
    `exec ${remoteCommandParts}`,
  ].join(" && ");

  return {
    command: "ssh",
    args: [
      ...auth.args,
      "-p",
      String(input.spec.port),
      `${input.spec.username}@${input.spec.host}`,
      `sh -c ${shellQuote(remoteScript)}`,
    ],
    stdinPrefix,
    cleanup: auth.cleanup,
  };
```

In `createSshCommandManagedRuntimeRunner.execute`, replace the lines from `const envEntries = …` down to the `runSshCommand` call with:

```ts
      const commandScript =
        (command === "sh" || command === "bash") &&
        (args[0] === "-c" || args[0] === "-lc") &&
        typeof args[1] === "string"
          ? args[1]
          : `exec ${[shellQuote(command), ...args.map((arg) => shellQuote(arg))].join(" ")}`;
      const remoteCommand = `cd ${shellQuote(cwd)} && ${commandScript}`;

      try {
        const result = await runSshCommand(input.spec, remoteCommand, {
          env: commandInput.env,
          stdin: commandInput.stdin,
          timeoutMs: commandInput.timeoutMs,
          maxBuffer: maxBufferBytes,
        });
```

(Side effect: a failed `cd` now stops `sh -c` scripts too, as it already did for other commands.)

- [ ] **Step 5: Implement in `server-utils.ts`.** Add the field to `SpawnTarget`:

```ts
interface SpawnTarget {
  command: string;
  args: string[];
  cwd?: string;
  env?: Record<string, string | undefined>;
  /** Written to stdin before the caller's own input (the SSH env block). */
  stdinPrefix?: string;
  cleanup?: () => Promise<void>;
}
```

In `resolveSpawnTarget`, in the remote branch's return object, add `stdinPrefix: spawnTarget.stdinPrefix,`.

In `runChildProcess`, replace `stdio: [opts.stdin != null ? "pipe" : "ignore", "pipe", "pipe"],` with:

```ts
          stdio: [stdinText != null ? "pipe" : "ignore", "pipe", "pipe"],
```

Declare `stdinText` just before the `spawn(...)` call:

```ts
        const stdinText =
          target.stdinPrefix || opts.stdin != null ? `${target.stdinPrefix ?? ""}${opts.stdin ?? ""}` : null;
```

Replace the stdin write block with:

```ts
        const stdin = child.stdin;
        if (stdinText != null && stdin) {
          void spawnPersistPromise.finally(() => {
            if (child.killed || stdin.destroyed) return;
            stdin.write(stdinText);
            stdin.end();
          });
        }
```

- [ ] **Step 6: Run the tests and see them pass.**

Run: `npx vitest run packages/adapter-utils/src/ssh-fixture.test.ts`
Expected: all PASS, including the four guard tests.

Run: `npx tsc --noEmit -p packages/adapter-utils`
Expected: no errors.

- [ ] **Step 7: Commit.**

```bash
git add packages/adapter-utils/src/ssh.ts packages/adapter-utils/src/server-utils.ts packages/adapter-utils/src/ssh-fixture.test.ts
git commit -m "fix(ssh): send env on stdin instead of argv"
```

---

### Task 3: Poll the bridge once a second over SSH

**Files:**
- Modify: `packages/adapter-utils/src/execution-target.ts` (the `startSandboxCallbackBridgeWorker({...})` call inside `startAdapterExecutionTargetPaperclipBridge`, near line 4807)

**Interfaces:** None.

This is a one-line constant, so no new test (ponytail: trivial one-liners need no test). After Task 1 each poll reuses one connection, so the value only limits how many remote shells run.

- [ ] **Step 1: Implement.** Add this line to the `startSandboxCallbackBridgeWorker({ ... })` argument object:

```ts
      // Over ssh every poll is a remote command; once a second is enough.
      pollIntervalMs: target.transport === "ssh" ? 1_000 : undefined,
```

- [ ] **Step 2: Type-check and run the bridge tests.**

Run: `npx tsc --noEmit -p packages/adapter-utils && npx vitest run packages/adapter-utils/src/execution-target-sandbox.test.ts`
Expected: no type errors; all PASS.

- [ ] **Step 3: Commit.**

```bash
git add packages/adapter-utils/src/execution-target.ts
git commit -m "fix(ssh): poll the callback bridge once a second over ssh"
```

---

### Task 4: Fix the SSH helper timeouts

**Files:**
- Modify: `packages/adapter-utils/src/execution-target.ts` (`runAdapterExecutionTargetShellCommand`, ssh branch, around lines 938–990)
- Test: `packages/adapter-utils/src/execution-target.test.ts`

**Interfaces:** No signature changes.

- [ ] **Step 1: Write the failing tests.** Add a shared target at the top of `execution-target.test.ts`:

```ts
const SSH_TARGET = {
  kind: "remote" as const,
  transport: "ssh" as const,
  remoteCwd: "/srv/paperclip/workspace",
  spec: {
    host: "ssh.example.test",
    port: 22,
    username: "ssh-user",
    remoteCwd: "/srv/paperclip/workspace",
    remoteWorkspacePath: "/srv/paperclip/workspace",
    privateKey: null,
    knownHosts: null,
    strictHostKeyChecking: true,
  },
};
```

Add inside `describe("runAdapterExecutionTargetShellCommand", ...)`:

```ts
  it("treats an execFile timeout (killed, no code) as timedOut", async () => {
    vi.spyOn(ssh, "runSshCommand").mockRejectedValue(
      Object.assign(new Error("Command failed"), { code: null, killed: true, signal: "SIGTERM", stdout: "", stderr: "" }),
    );

    const result = await runAdapterExecutionTargetShellCommand("run-t1", SSH_TARGET, "sleep 99", {
      cwd: "/tmp/local",
      env: {},
    });

    expect(result).toMatchObject({ exitCode: null, signal: "SIGTERM", timedOut: true });
  });

  it("does not report a maxBuffer overflow as a timeout", async () => {
    vi.spyOn(ssh, "runSshCommand").mockRejectedValue(
      Object.assign(new Error("stdout maxBuffer length exceeded"), {
        code: "ERR_CHILD_PROCESS_STDIO_MAXBUFFER",
        killed: true,
        signal: "SIGTERM",
      }),
    );

    await expect(
      runAdapterExecutionTargetShellCommand("run-t2", SSH_TARGET, "yes", { cwd: "/tmp/local", env: {} }),
    ).rejects.toThrow("maxBuffer");
  });

  it("uses the default helper timeout when timeoutSec is 0", async () => {
    const spy = vi.spyOn(ssh, "runSshCommand").mockResolvedValue({ stdout: "", stderr: "" });

    await runAdapterExecutionTargetShellCommand("run-t3", SSH_TARGET, "true", {
      cwd: "/tmp/local",
      env: {},
      timeoutSec: 0,
    });

    expect(spy).toHaveBeenCalledWith(expect.anything(), "true", expect.objectContaining({ timeoutMs: 15_000 }));
  });
```

- [ ] **Step 2: Run them and see them fail.**

Run: `npx vitest run packages/adapter-utils/src/execution-target.test.ts -t "execFile timeout|maxBuffer overflow|timeoutSec is 0"`
Expected: two FAIL. The first rejects with `Command failed`. The third is called with `timeoutMs: 0`. The maxBuffer test already passes as a guard.

- [ ] **Step 3: Implement.** In the ssh branch of `runAdapterExecutionTargetShellCommand`, change the `runSshCommand` options to:

```ts
        const result = await runSshCommand(target.spec, command, {
          env,
          // `0` means "use the default", not "no timeout": a hung helper must not hang the run.
          timeoutMs: (options.timeoutSec && options.timeoutSec > 0 ? options.timeoutSec : 15) * 1000,
        });
```

Add `killed?: boolean;` to the `timedOutError` type. Then replace `if (timedOutError.code !== "ETIMEDOUT") {` with:

```ts
        // execFile reports its own timeout as `killed` with no exit code, not ETIMEDOUT.
        const isTimeout =
          timedOutError.code === "ETIMEDOUT" || (timedOutError.killed === true && timedOutError.code == null);
        if (!isTimeout) {
```

- [ ] **Step 4: Run them and see them pass,** together with the existing timeout test.

Run: `npx vitest run packages/adapter-utils/src/execution-target.test.ts -t "runAdapterExecutionTargetShellCommand"`
Expected: all PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/adapter-utils/src/execution-target.ts packages/adapter-utils/src/execution-target.test.ts
git commit -m "fix(ssh): default zero helper timeouts and detect execFile timeouts"
```

---

### Task 5: Allow cost events on the bridge

**Files:**
- Modify: `packages/adapter-utils/src/sandbox-callback-bridge.ts` (`DEFAULT_SANDBOX_CALLBACK_BRIDGE_ROUTE_ALLOWLIST`)
- Test: `packages/adapter-utils/src/sandbox-callback-bridge.test.ts`

**Interfaces:** None. The server already limits an agent to reporting its own costs (`server/src/routes/costs.ts`: "Agent can only report its own costs"), and `skills/paperclip/references/api-reference.md` already documents the route.

- [ ] **Step 1: Write the failing test.** Add it in the same `describe` as `"denies non-allowlisted requests by default"`:

```ts
  it("allows agents to report cost events through the bridge", () => {
    expect(
      authorizeSandboxCallbackBridgeRequestWithRoutes({ method: "POST", path: "/api/companies/company-1/cost-events" }),
    ).toBeNull();
    expect(
      authorizeSandboxCallbackBridgeRequestWithRoutes({ method: "GET", path: "/api/companies/company-1/cost-events" }),
    ).toBe("Route not allowed: GET /api/companies/company-1/cost-events");
  });
```

- [ ] **Step 2: Run it and see it fail.**

Run: `npx vitest run packages/adapter-utils/src/sandbox-callback-bridge.test.ts -t "cost events"`
Expected: FAIL. It receives `"Route not allowed: POST /api/companies/company-1/cost-events"`.

- [ ] **Step 3: Implement.** Add this entry to `DEFAULT_SANDBOX_CALLBACK_BRIDGE_ROUTE_ALLOWLIST`, after the issue routes:

```ts
  // Costs: remote agents report non-token usage such as GPU-hours. The server
  // only accepts an agent's own costs.
  { method: "POST", path: /^\/api\/companies\/[^/]+\/cost-events$/ },
```

- [ ] **Step 4: Run it and see it pass.**

Run: `npx vitest run packages/adapter-utils/src/sandbox-callback-bridge.test.ts`
Expected: all PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/adapter-utils/src/sandbox-callback-bridge.ts packages/adapter-utils/src/sandbox-callback-bridge.test.ts
git commit -m "fix(bridge): allow agents to report cost events"
```

---

### Task 6: Delete the per-run remote copy after restore

**Files:**
- Modify: `packages/adapter-utils/src/remote-managed-runtime.ts` (new export `remoteRunDirForCleanup`; `restoreWorkspace` inside `prepareRemoteManagedRuntime`; add `shellQuote` to the `./ssh.js` import)
- Test: `packages/adapter-utils/src/remote-managed-runtime.test.ts`, `packages/adapter-utils/src/ssh-fixture.test.ts`

**Interfaces:**
- Produces: `export function remoteRunDirForCleanup(baseWorkspaceRemoteDir: string, runId: string): string | null`

- [ ] **Step 1: Write the failing tests.** In `remote-managed-runtime.test.ts`, import `remoteRunDirForCleanup` and add:

```ts
describe("remoteRunDirForCleanup", () => {
  it("returns the per-run directory for a normal run id", () => {
    expect(remoteRunDirForCleanup("/srv/ws", "3f0c1c9e-1b2a-4c3d-8e9f-0a1b2c3d4e5f")).toBe(
      "/srv/ws/.paperclip-runtime/runs/3f0c1c9e-1b2a-4c3d-8e9f-0a1b2c3d4e5f",
    );
  });

  it("refuses empty, dot and path-like run ids", () => {
    for (const runId of ["", ".", "..", "../x", "a/b", " x"]) {
      expect(remoteRunDirForCleanup("/srv/ws", runId)).toBeNull();
    }
  });
});
```

In `ssh-fixture.test.ts`, add:

```ts
  it("removes the per-run remote copy after a successful restore", async () => {
    const rootDir = await createFixtureRootDir();
    const statePath = path.join(rootDir, "state.json");
    const localRepo = path.join(rootDir, "local-workspace");
    await mkdir(localRepo, { recursive: true });
    await git(localRepo, ["init"]);
    await git(localRepo, ["checkout", "-b", "main"]);
    await git(localRepo, ["config", "user.name", "Paperclip Test"]);
    await git(localRepo, ["config", "user.email", "test@paperclip.dev"]);
    await writeFile(path.join(localRepo, "tracked.txt"), "base\n", "utf8");
    await git(localRepo, ["add", "tracked.txt"]);
    await git(localRepo, ["commit", "-m", "initial"]);

    const started = await startSshEnvLabFixtureOrSkip(statePath, "SSH run-directory cleanup test");
    if (!started) return;
    const config = await buildSshEnvLabFixtureConfig(started);
    const prepared = await prepareRemoteManagedRuntime({
      spec: { ...config, remoteCwd: started.workspaceDir },
      runId: "run-cleanup",
      adapterKey: "test-adapter",
      workspaceLocalDir: localRepo,
    });
    const runDir = path.posix.dirname(prepared.workspaceRemoteDir);

    await prepared.restoreWorkspace();

    const probe = await runSshCommand(config, `test -e ${JSON.stringify(runDir)} && echo present || echo gone`, {
      timeoutMs: 30_000,
    });
    expect(probe.stdout.trim()).toBe("gone");
  }, SSH_FIXTURE_TEST_TIMEOUT_MS);
```

- [ ] **Step 2: Run them and see them fail.**

Run: `npx vitest run packages/adapter-utils/src/remote-managed-runtime.test.ts -t "remoteRunDirForCleanup"`
Expected: FAIL with `remoteRunDirForCleanup is not a function`.

Run: `npx vitest run packages/adapter-utils/src/ssh-fixture.test.ts -t "per-run remote copy"`
Expected: FAIL with `expected 'present' to be 'gone'`.

- [ ] **Step 3: Implement.** In `remote-managed-runtime.ts`, add `shellQuote` to the `./ssh.js` import and add:

```ts
/** The per-run directory to delete after a restore, or null when deleting would be unsafe. */
export function remoteRunDirForCleanup(baseWorkspaceRemoteDir: string, runId: string): string | null {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(runId)) return null;
  return path.posix.join(baseWorkspaceRemoteDir, ".paperclip-runtime", "runs", runId);
}
```

At the end of `restoreWorkspace` (after the assets loop), add the code below. It runs only after the restore succeeded, because a failed restore throws before reaching it and leaves the copy in place for recovery.

```ts
      // The per-run copy is only needed until its changes are restored.
      const runDir = syncWorkspace ? remoteRunDirForCleanup(baseWorkspaceRemoteDir, input.runId) : null;
      if (runDir) {
        await runSshCommand(input.spec, `rm -rf ${shellQuote(runDir)}`, { timeoutMs: 60_000 }).catch((error) => {
          console.warn(`[paperclip] Failed to remove remote run directory ${runDir}: ${String(error)}`);
        });
      }
```

- [ ] **Step 4: Run them and see them pass.**

Run: `npx vitest run packages/adapter-utils/src/remote-managed-runtime.test.ts packages/adapter-utils/src/ssh-fixture.test.ts`
Expected: all PASS. The unit file mocks `./ssh.js` but uses `syncWorkspace: false`, so the cleanup path does not run there.

- [ ] **Step 5: Commit.**

```bash
git add packages/adapter-utils/src/remote-managed-runtime.ts packages/adapter-utils/src/remote-managed-runtime.test.ts packages/adapter-utils/src/ssh-fixture.test.ts
git commit -m "fix(ssh): delete the per-run remote copy after a successful restore"
```

---

### Task 7: Verify and open the PR

**Files:** none new.

- [ ] **Step 1: Type-check the changed packages.**

Run: `npx tsc --noEmit -p packages/adapter-utils && npx tsc --noEmit -p server`
Expected: no errors.

- [ ] **Step 2: Run every test that imports a changed file.**

Run: `PATH="<dir with a pnpm@9.15.4 shim>:$PATH" npx vitest run --changed master --testTimeout=120000`
Expected: all PASS, except known environment-only failures on machines without `pnpm` or `cargo` (`workspace-runtime`, `plugin-install-autobuild`, `native-codex-runner`). Name any other failure in the PR and research it before merging.

- [ ] **Step 3 (optional, needs a real host): the live SSH test.**

Run: `PAPERCLIP_ENV_LIVE_SSH_HOST=… PAPERCLIP_ENV_LIVE_SSH_USER=… npx vitest run server/src/__tests__/environment-live-ssh.test.ts` (see that file for the full variable list).
Expected: PASS.

- [ ] **Step 4: Open the PR** with `.github/PULL_REQUEST_TEMPLATE.md` (Simplified Technical English, `Refs #5`, Model Used). Run `/ponytail:ponytail-review` on the diff, apply the cuts, and have `gabenavarro` merge with a squash.

## Self-review record

- Spec coverage: Part 1 items 1–6 map to Tasks 1–6, and Task 7 is verification. Parts 2–6 are configuration, runbook and content work; they go in the next plan (HPC company package).
- Type consistency: `encodeSshEnvStdin` (local to `ssh.ts`), `stdinPrefix` and `remoteRunDirForCleanup` use the same names in every task.
- Local-agent note: agents that run in the Paperclip container run as the same Unix user as the server. They could use a live control socket, but they can already read the server's environment, so the socket does not widen that boundary. The directory is `0700`.
