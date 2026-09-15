// Minimal Sentry error reporting for Edge Functions — deliberately has no SDK
// dependency. This repo avoids esm.sh / deno.land x-imports for Deno function
// code (see push.ts / create-booking-request's header comments — both flaked
// during deploys), so this talks to Sentry's ingestion API directly over a
// plain `fetch`, using only the DSN.
//
// Set the `SENTRY_DSN` secret (`supabase secrets set SENTRY_DSN=...`) to
// enable reporting. If unset or unparsable, captureException() is a no-op —
// it never throws and never blocks/breaks the caller's actual response.

interface ParsedDsn {
  publicKey: string;
  host: string;
  projectId: string;
}

function parseDsn(dsn: string): ParsedDsn | null {
  try {
    const url = new URL(dsn);
    const projectId = url.pathname.replace(/^\//, "");
    if (!url.username || !projectId) return null;
    return { publicKey: url.username, host: url.host, projectId };
  } catch {
    return null;
  }
}

/**
 * Reports an exception to Sentry via the legacy Store API (needs nothing
 * beyond the DSN — no SDK). Fire-and-forget from the caller's perspective:
 * always resolves, never rejects, so a Sentry outage can't break a function.
 */
export async function captureException(
  error: unknown,
  context?: { functionName?: string; extra?: Record<string, unknown> },
): Promise<void> {
  const dsn = Deno.env.get("SENTRY_DSN");
  if (!dsn) return;

  const parsed = parseDsn(dsn);
  if (!parsed) {
    console.error(
      "[sentry] SENTRY_DSN is set but could not be parsed — skipping report",
    );
    return;
  }

  try {
    const message = error instanceof Error ? error.message : String(error);
    const errorType = error instanceof Error ? error.name : "Error";
    const stack = error instanceof Error ? error.stack : undefined;

    const payload = {
      message,
      level: "error",
      platform: "other",
      environment: Deno.env.get("APP_ENV") ?? "production",
      tags: { function: context?.functionName ?? "unknown" },
      extra: { ...(context?.extra ?? {}), stack },
      exception: {
        values: [{ type: errorType, value: message }],
      },
    };

    const authHeader =
      `Sentry sentry_version=7, sentry_key=${parsed.publicKey}, ` +
      `sentry_client=parkingtrade-edge/1.0`;

    await fetch(`https://${parsed.host}/api/${parsed.projectId}/store/`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Sentry-Auth": authHeader,
      },
      body: JSON.stringify(payload),
    });
  } catch (reportError) {
    // Never let error reporting itself break the caller.
    console.error(
      `[sentry] Failed to report exception: ${
        (reportError as Error)?.message ?? reportError
      }`,
    );
  }
}
