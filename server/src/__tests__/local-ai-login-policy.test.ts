import { afterEach, describe, expect, it, vi } from "vitest";
import { supportsLocalAiLogin } from "../services/local-ai-login-policy.js";
describe("server-host subscription login policy", () => {
  it("permits private self-hosted instances and explicit trusted hosts", () => {
    expect(supportsLocalAiLogin({ deploymentMode: "local_trusted", deploymentExposure: "private" })).toBe(true);
    expect(supportsLocalAiLogin({ deploymentMode: "authenticated", deploymentExposure: "private" })).toBe(true);
    expect(supportsLocalAiLogin({ deploymentMode: "authenticated", deploymentExposure: "public", trustedLocalStdioRuntimeHost: "trusted-host" })).toBe(true);
    expect(supportsLocalAiLogin({ deploymentMode: "authenticated", deploymentExposure: "public", trustedLocalStdioRuntimeHost: "" })).toBe(false);
  });

  afterEach(() => vi.unstubAllEnvs());
  it("lets the operator turn it off, even on a trusted host", () => {
    vi.stubEnv("PAPERCLIP_LOCAL_AI_LOGIN_ENABLED", "false");
    expect(supportsLocalAiLogin({ deploymentMode: "authenticated", deploymentExposure: "public", trustedLocalStdioRuntimeHost: "cloud-run" })).toBe(false);
    expect(supportsLocalAiLogin({ deploymentMode: "local_trusted", deploymentExposure: "private" })).toBe(false);
  });
});
