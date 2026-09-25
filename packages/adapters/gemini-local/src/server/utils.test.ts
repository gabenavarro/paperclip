import { describe, expect, it, vi } from "vitest";
import { detectGeminiCredentials, resolveGeminiBillingType } from "./utils.js";

const VERTEX_ENV = {
  GOOGLE_GENAI_USE_VERTEXAI: "true",
  GOOGLE_CLOUD_PROJECT: "vertex-project",
  GOOGLE_CLOUD_LOCATION: "global",
};

describe("detectGeminiCredentials", () => {
  it("labels API keys from adapter config", () => {
    expect(
      detectGeminiCredentials({ configEnv: { GEMINI_API_KEY: "key" }, hostEnv: null, acp: false }),
    ).toEqual({ source: "adapter config env", vertexNeedsAcpxAuth: false });
  });

  it("reads the server environment only for local targets", () => {
    const hostEnv = { GOOGLE_API_KEY: "key" };
    expect(detectGeminiCredentials({ configEnv: {}, hostEnv: null, acp: false }).source).toBeNull();
    expect(detectGeminiCredentials({ configEnv: {}, hostEnv, acp: false }).source).toBe("server environment");
  });

  it("labels Google account login", () => {
    expect(
      detectGeminiCredentials({ configEnv: { GOOGLE_GENAI_USE_GCA: "true" }, hostEnv: null, acp: false }).source,
    ).toBe("Google account login (GCA)");
  });

  it("detects Vertex AI with Application Default Credentials for the CLI engine", () => {
    expect(detectGeminiCredentials({ configEnv: {}, hostEnv: VERTEX_ENV, acp: false })).toEqual({
      source: "Vertex AI (Application Default Credentials)",
      vertexNeedsAcpxAuth: false,
    });
  });

  it("needs ACPX_AUTH_VERTEX_AI on the server before the ACP engine can use Vertex AI", () => {
    vi.stubEnv("ACPX_AUTH_VERTEX_AI", "");
    expect(
      detectGeminiCredentials({ configEnv: {}, hostEnv: VERTEX_ENV, acp: true }),
    ).toEqual({ source: null, vertexNeedsAcpxAuth: true });
    vi.stubEnv("ACPX_AUTH_VERTEX_AI", "1");
    expect(
      detectGeminiCredentials({ configEnv: {}, hostEnv: VERTEX_ENV, acp: true }).source,
    ).toBe("Vertex AI (Application Default Credentials)");
    vi.unstubAllEnvs();
  });

  it("does not count the Vertex flag without a project and location", () => {
    expect(
      detectGeminiCredentials({
        configEnv: { GOOGLE_GENAI_USE_VERTEXAI: "true" },
        hostEnv: null,
        acp: false,
      }).source,
    ).toBeNull();
  });
});

describe("resolveGeminiBillingType", () => {
  it("bills API keys and Vertex AI as api usage", () => {
    expect(resolveGeminiBillingType({ GEMINI_API_KEY: "key" })).toBe("api");
    expect(resolveGeminiBillingType(VERTEX_ENV)).toBe("api");
  });

  it("treats Google account login as a subscription", () => {
    expect(resolveGeminiBillingType({ GOOGLE_GENAI_USE_GCA: "true" })).toBe("subscription");
  });
});
