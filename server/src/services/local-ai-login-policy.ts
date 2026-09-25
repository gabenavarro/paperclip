import type { DeploymentMode, DeploymentExposure } from "@paperclipai/shared";

/**
 * Same server-host boundary as local stdio runtimes, unless the operator turns
 * it off: a hosted server (Cloud Run) keeps trusted runtimes but has no
 * terminal for a user to sign in from.
 */
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
