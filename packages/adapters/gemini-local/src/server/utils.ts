export function firstNonEmptyLine(text: string): string {
    return (
        text
            .split(/\r?\n/)
            .map((line) => line.trim())
            .find(Boolean) ?? ""
    );
}

function nonEmpty(value: unknown): value is string {
    return typeof value === "string" && value.trim().length > 0;
}

/**
 * Which Gemini credential a run can use, for the environment checks. Adapter
 * config env always counts; the server's env (`hostEnv`) counts only for local
 * targets, because a remote sandbox does not inherit it (pass `null`). Vertex AI
 * needs `GOOGLE_GENAI_USE_VERTEXAI=true` plus a project and location; the
 * identity comes from Application Default Credentials. The ACP engine uses
 * Vertex only when acpx selects the `vertex-ai` auth method, which it does from
 * `ACPX_AUTH_VERTEX_AI` in the Paperclip server's own environment.
 * Precedence follows Gemini CLI: Google account login, then Vertex, then keys.
 */
export function detectGeminiCredentials(input: {
    configEnv: Record<string, unknown>;
    hostEnv: Record<string, string | undefined> | null;
    acp: boolean;
}): { source: string | null; vertexNeedsAcpxAuth: boolean } {
    const read = (key: string) => (nonEmpty(input.configEnv[key]) ? input.configEnv[key] : input.hostEnv?.[key]);
    const vertexConfigured =
        read("GOOGLE_GENAI_USE_VERTEXAI") === "true" &&
        nonEmpty(read("GOOGLE_CLOUD_PROJECT")) &&
        nonEmpty(read("GOOGLE_CLOUD_LOCATION"));
    const vertexNeedsAcpxAuth =
        vertexConfigured && input.acp && !nonEmpty(process.env.ACPX_AUTH_VERTEX_AI);

    let source: string | null = null;
    if (read("GOOGLE_GENAI_USE_GCA") === "true") source = "Google account login (GCA)";
    else if (vertexConfigured && !vertexNeedsAcpxAuth) source = "Vertex AI (Application Default Credentials)";
    else if (nonEmpty(input.configEnv.GEMINI_API_KEY) || nonEmpty(input.configEnv.GOOGLE_API_KEY)) {
        source = "adapter config env";
    } else if (nonEmpty(input.hostEnv?.GEMINI_API_KEY) || nonEmpty(input.hostEnv?.GOOGLE_API_KEY)) {
        source = "server environment";
    }
    return { source, vertexNeedsAcpxAuth };
}

/** API keys and Vertex AI are metered usage; Google account login is a subscription. */
export function resolveGeminiBillingType(env: Record<string, string>): "api" | "subscription" {
    return nonEmpty(env.GEMINI_API_KEY) || nonEmpty(env.GOOGLE_API_KEY) || env.GOOGLE_GENAI_USE_VERTEXAI === "true"
        ? "api"
        : "subscription";
}
