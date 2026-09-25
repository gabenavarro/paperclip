import type { DeploymentMode, DeploymentExposure } from "@paperclipai/shared";

/** Same server-host boundary as local stdio runtimes. `PAPERCLIP_LOCAL_AI_LOGIN_ENABLED=false`
 * turns it off (a hosted server has no terminal). */
export function supportsLocalAiLogin(options: {
  deploymentMode?: DeploymentMode;
  deploymentExposure?: DeploymentExposure;
  trustedLocalStdioRuntimeHost?: string | null;
}) {
  if (process.env.PAPERCLIP_LOCAL_AI_LOGIN_ENABLED === "false") return false;
  return options.deploymentMode !== "authenticated" || options.deploymentExposure !== "public" || Boolean(
    options.trustedLocalStdioRuntimeHost ?? process.env.PAPERCLIP_TRUSTED_MCP_RUNTIME_HOST ?? process.env.PAPERCLIP_TOOL_RUNTIME_TRUSTED_HOST,
  );
}
