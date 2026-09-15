#!/usr/bin/env bash
# Bootstrap the currently-linked Supabase environment to a fully-working state
# AFTER `supabase db push`. Idempotent — safe to run on every deploy.
#
#   1. Sets the Edge Function runtime secrets (FIREBASE_SERVICE_ACCOUNT,
#      PLACES_API_KEY) so the GitHub secret is the single source of truth.
#   2. Runs supabase/bootstrap/bootstrap.sql (pg_cron jobs + Vault secrets).
#   3. Asserts the verification counts (5 cron jobs, 6 vault secrets).
#
# The Postgres connection is derived, not configured: `supabase link` (run in the
# deploy job just before this script) writes `supabase/.temp/pooler-url` —
# already tenant-qualified (postgres.<ref>@aws-N-<region>.pooler.supabase.com) —
# and we inject the password via PGPASSWORD. No connection-string secret, no
# region/host guessing, no URI percent-encoding footgun.
#
# Required environment:
#   SUPABASE_PROJECT_REF      — linked project ref (for `supabase secrets set`)
#   SUPABASE_DB_PASSWORD      — database password (injected via PGPASSWORD)
#   FUNCTIONS_BASE_URL        — https://<ref>.supabase.co  (== SUPABASE_URL)
#   SERVICE_ROLE_KEY          — service_role secret
#   FIREBASE_SERVICE_ACCOUNT  — FCM v1 service-account JSON
#   PLACES_API_KEY            — Google Places key
#
# Optional environment:
#   SENTRY_DSN                — Sentry DSN for Edge Function error reporting
#                                (_shared/sentry.ts). Omit to leave it unset —
#                                functions run with Sentry reporting disabled.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SUPABASE_PROJECT_REF:?}"
: "${SUPABASE_DB_PASSWORD:?}"
: "${FUNCTIONS_BASE_URL:?}"
: "${SERVICE_ROLE_KEY:?}"
: "${FIREBASE_SERVICE_ACCOUNT:?}"
: "${PLACES_API_KEY:?}"
: "${SENTRY_DSN:=}"

POOLER_URL_FILE="supabase/.temp/pooler-url"
if [ ! -s "$POOLER_URL_FILE" ]; then
  echo "::error::$POOLER_URL_FILE missing — run 'supabase link --project-ref \$SUPABASE_PROJECT_REF' before this script" >&2
  exit 1
fi
DB_URL="$(tr -d '[:space:]' < "$POOLER_URL_FILE")"

# The pooler URL carries no password; keep it that way and pass the secret via
# PGPASSWORD so it never appears in a URI, a process arg, or a log.
export PGPASSWORD="$SUPABASE_DB_PASSWORD"

# Keep secret values out of any accidental `set -x` / log echo.
echo "::add-mask::${SERVICE_ROLE_KEY}"
echo "::add-mask::${PLACES_API_KEY}"
echo "::add-mask::${SUPABASE_DB_PASSWORD}"

echo "▶ Syncing Edge Function runtime secrets…"
supabase secrets set --project-ref "$SUPABASE_PROJECT_REF" \
  FIREBASE_SERVICE_ACCOUNT="$FIREBASE_SERVICE_ACCOUNT" \
  PLACES_API_KEY="$PLACES_API_KEY" >/dev/null
if [ -n "$SENTRY_DSN" ]; then
  echo "::add-mask::${SENTRY_DSN}"
  supabase secrets set --project-ref "$SUPABASE_PROJECT_REF" \
    SENTRY_DSN="$SENTRY_DSN" >/dev/null
fi
echo "  done."

echo "▶ Running bootstrap.sql (pg_cron + Vault) via ${DB_URL%%@*}@…"
OUT="$(psql "$DB_URL" \
  --no-psqlrc --quiet --tuples-only --no-align --field-separator='=' \
  -v functions_base_url="$FUNCTIONS_BASE_URL" \
  -v service_role_key="$SERVICE_ROLE_KEY" \
  -f supabase/bootstrap/bootstrap.sql)"
echo "$OUT"

cron_jobs="$(printf '%s\n'  "$OUT" | awk -F= '$1=="cron jobs"{print $2}')"
vault_secrets="$(printf '%s\n' "$OUT" | awk -F= '$1=="vault secrets"{print $2}')"

fail=0
[ "${cron_jobs:-0}" -ge 5 ]     || { echo "::error::expected >=5 cron jobs, got '${cron_jobs:-}'"; fail=1; }
[ "${vault_secrets:-0}" -eq 6 ] || { echo "::error::expected 6 vault secrets, got '${vault_secrets:-}'"; fail=1; }
printf '%s\n' "$OUT" | grep -q 'pg_cron ext=MISSING' && { echo "::error::pg_cron extension missing"; fail=1; }
printf '%s\n' "$OUT" | grep -q 'pg_net ext=MISSING'  && { echo "::error::pg_net extension missing";  fail=1; }
[ "$fail" -eq 0 ] || { echo "Bootstrap verification FAILED." >&2; exit 1; }

echo "✅ Bootstrap complete: ${cron_jobs} cron jobs, ${vault_secrets} vault secrets."
