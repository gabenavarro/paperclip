import { useState } from "react";
import { authApi } from "../api/auth";
import { Button } from "@/components/ui/button";

/** Text for the `?error=` code Better Auth appends to the OAuth error callback URL. */
export function describeOAuthError(code: string | null): string | null {
  if (!code) return null;
  if (code === "unable_to_create_user") return "This Google account is not allowed on this instance.";
  return `Google sign-in failed (${code}). Try again.`;
}

export function GoogleSignInButton({
  callbackURL,
  errorCallbackURL,
  onBeforeRedirect,
}: {
  callbackURL: string;
  errorCallbackURL: string;
  onBeforeRedirect?: () => void;
}) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  return (
    <div>
      <Button
        type="button"
        variant="outline"
        className="w-full"
        disabled={pending}
        onClick={async () => {
          setPending(true);
          setError(null);
          onBeforeRedirect?.();
          try {
            await authApi.signInSocial({ provider: "google", callbackURL, errorCallbackURL });
          } catch (err) {
            setError(err instanceof Error ? err.message : "Google sign-in failed");
            setPending(false);
          }
        }}
      >
        {pending ? "Redirecting…" : "Continue with Google"}
      </Button>
      {error && (
        <p role="alert" className="mt-2 text-xs text-destructive">
          {error}
        </p>
      )}
    </div>
  );
}
