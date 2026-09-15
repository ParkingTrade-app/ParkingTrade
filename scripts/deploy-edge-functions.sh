#!/usr/bin/env bash
# Deploy EVERY Edge Function to the currently-linked Supabase project.
#
# This is the single canonical list — the CI/CD workflows call this script
# instead of each carrying their own hardcoded `for fn in ...` block. When you
# add a function, add it here (once) and nowhere else.
#
# Excludes _shared/ (shared utilities, not a deployable function).
#
# Prereq: the project is already linked (`supabase link --project-ref ...`) and
# SUPABASE_ACCESS_TOKEN is set.
set -euo pipefail
cd "$(dirname "$0")/.."

FUNCTIONS=(
  admin-bulk-import
  approve-booking
  create-booking-request
  create-building
  create-building-admin
  join-building
  manage-member
  notify-building-announcement
  notify-spot-available
  notify-waitlist-match
  notify-booking-issue
  places-autocomplete
  review-join-request
  send-chat-message
  submit-join-request
)

# Guard: every function directory on disk must be in the list above (catches a
# newly-added function that someone forgot to register here).
missing=0
for dir in supabase/functions/*/; do
  name="$(basename "$dir")"
  [ "$name" = "_shared" ] && continue
  case " ${FUNCTIONS[*]} " in
    *" $name "*) ;;
    *) echo "ERROR: supabase/functions/$name exists but is not in deploy-edge-functions.sh" >&2; missing=1 ;;
  esac
done
[ "$missing" -eq 0 ] || exit 1

for fn in "${FUNCTIONS[@]}"; do
  echo "▶ Deploying edge function: $fn"
  supabase functions deploy "$fn"
done
echo "✅ All ${#FUNCTIONS[@]} Edge Functions deployed."
