import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import postgres from "postgres";
import { afterEach, describe, expect, it } from "vitest";
import {
  EMBEDDED_POSTGRES_TEST_TIMEOUT_MS,
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./test-embedded-postgres.js";

const execFileAsync = promisify(execFile);
const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cleanups: Array<() => Promise<void>> = [];
const support = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = support.supported ? describe : describe.skip;

afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()?.();
});

describeEmbeddedPostgres("create-auth-bootstrap-invite", () => {
  it(
    "creates the first-admin invite from DATABASE_URL when no config file is given",
    async () => {
      const database = await startEmbeddedPostgresTestDatabase("paperclip-bootstrap-invite-");
      cleanups.push(database.cleanup);

      // Cloud Run Jobs have no Paperclip config file: only the env the job carries.
      const { stdout } = await execFileAsync(
        process.execPath,
        ["--import", "tsx", "scripts/create-auth-bootstrap-invite.ts", "--base-url", "https://board.example.test/"],
        { cwd: packageDir, env: { ...process.env, DATABASE_URL: database.connectionString } },
      );

      const match = stdout.trim().match(/^https:\/\/board\.example\.test\/invite\/(pcp_bootstrap_[0-9a-f]{48})$/);
      expect(match).not.toBeNull();

      const sql = postgres(database.connectionString, { max: 1, onnotice: () => {} });
      cleanups.push(async () => sql.end());
      const rows = await sql`select invite_type, token_hash from invites where revoked_at is null`;
      expect(rows).toEqual([
        {
          invite_type: "bootstrap_ceo",
          token_hash: createHash("sha256").update(match![1]!).digest("hex"),
        },
      ]);
    },
    EMBEDDED_POSTGRES_TEST_TIMEOUT_MS,
  );
});
