-- ============================================================================
-- ParkingTrade — per-environment bootstrap. IDEMPOTENT. Safe to run repeatedly.
--
-- Runs AFTER `supabase db push`. This is deliberately NOT a migration: it
-- carries an environment-specific Functions URL and the service_role key,
-- neither of which may ever live in a git-committed migration file
-- (see supabase/migrations/039_spot_availability_webhook.sql header for the
-- full rationale — TG_ARGV can't be a runtime expression, and ALTER DATABASE
-- SET needs superuser which the Supabase `postgres` role is not).
--
-- What it does, all idempotently:
--   1. Ensures pg_cron + pg_net extensions exist.
--   2. Upserts the 6 feature-scoped Vault secrets that the migration-039/040/044
--      pg_net webhook triggers read (real-time push delivery).
--   3. (Re)schedules the 6 pg_cron jobs (booking completion, waitlist expiry,
--      waitlist-vs-upcoming-availability backfill, and the 3 notification-outbox
--      drains — the durability backstop).
--   4. Prints a verification summary (the deploy step asserts the counts).
--
-- Usage (normally invoked by scripts/bootstrap-env.sh, which derives the
-- connection from supabase/.temp/pooler-url + PGPASSWORD):
--   PGPASSWORD="<db password>" psql "$(cat supabase/.temp/pooler-url)" \
--     -v functions_base_url="https://<project-ref>.supabase.co" \
--     -v service_role_key="<service_role secret — Dashboard → Project Settings → API>" \
--     -f supabase/bootstrap/bootstrap.sql
--
-- Rotating the service_role key? Re-run this script: it refreshes both the Vault
-- secrets AND the cron drain commands (the key is embedded literally in each
-- `cron.job.command`).
-- ============================================================================

\set ON_ERROR_STOP on

-- psql `:'var'` does not interpolate inside dollar-quoted bodies, so stash the
-- two inputs in session GUCs the DO blocks below can read via current_setting().
-- Results go to /dev/null so the service_role key is never echoed to the log.
\o /dev/null
SELECT set_config('bootstrap.fn_url',  :'functions_base_url', false);
SELECT set_config('bootstrap.svc_key', :'service_role_key',   false);
\o

-- Fail early on an obviously-wrong URL (the webhook triggers append
-- '/functions/v1/...', so this must be the bare project origin).
DO $$
BEGIN
  IF current_setting('bootstrap.fn_url') !~ '^https?://[^/]+$' THEN
    RAISE EXCEPTION 'functions_base_url must be a bare origin like https://<ref>.supabase.co (got: %)',
      current_setting('bootstrap.fn_url');
  END IF;
  IF length(current_setting('bootstrap.svc_key')) < 40 THEN
    RAISE EXCEPTION 'service_role_key looks too short — pass the real service_role secret';
  END IF;
END $$;

-- 1. Extensions --------------------------------------------------------------
--    On hosted Supabase these may also need enabling via Dashboard → Database →
--    Extensions; if so, that is the single manual pre-step and this errors loud.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 2. Vault secrets ---------------------------------------------------------
--    3 pipelines (announcement / spot / waitlist) × (base_url, service_role_key).
--    Feature-scoped on purpose so each pipeline rotates/disables independently.
DO $$
DECLARE
  v_url  text := current_setting('bootstrap.fn_url');
  v_key  text := current_setting('bootstrap.svc_key');
  rec    record;
  sec_id uuid;
BEGIN
  FOR rec IN
    SELECT * FROM (VALUES
      ('announcement_notify_functions_base_url', v_url),
      ('announcement_notify_service_role_key',   v_key),
      ('spot_notify_functions_base_url',         v_url),
      ('spot_notify_service_role_key',           v_key),
      ('waitlist_notify_functions_base_url',     v_url),
      ('waitlist_notify_service_role_key',       v_key)
    ) AS t(name, val)
  LOOP
    SELECT id INTO sec_id FROM vault.secrets WHERE name = rec.name;
    IF sec_id IS NULL THEN
      PERFORM vault.create_secret(rec.val, rec.name,
        'ParkingTrade notification pipeline — managed by supabase/bootstrap/bootstrap.sql');
    ELSE
      PERFORM vault.update_secret(sec_id, rec.val);
    END IF;
  END LOOP;
END $$;

-- 3. pg_cron jobs --------------------------------------------------------
--    Unschedule-then-schedule = safe on every pg_cron version.
DO $$
DECLARE
  fn_url    text := current_setting('bootstrap.fn_url');
  svc_key   text := current_setting('bootstrap.svc_key');
  rec       record;
  drain_tpl constant text :=
    $t$SELECT net.http_post(
         url     := %L,
         headers := jsonb_build_object(
                      'Content-Type', 'application/json',
                      'Authorization', %L))$t$;
BEGIN
  FOR rec IN
    SELECT * FROM (VALUES
      ('complete-bookings',
       '*/15 * * * *',
       'SELECT complete_expired_bookings()'),

      ('expire-waitlist',
       '*/15 * * * *',
       'SELECT expire_waitlist_entries()'),

      ('match-waitlist-upcoming',
       '*/15 * * * *',
       'SELECT match_waitlist_against_upcoming_availability()'),

      ('drain-waitlist-notifications',
       '*/2 * * * *',
       format(drain_tpl, fn_url || '/functions/v1/notify-waitlist-match',
              'Bearer ' || svc_key)),

      ('drain-spot-availability-notifications',
       '*/2 * * * *',
       format(drain_tpl, fn_url || '/functions/v1/notify-spot-available',
              'Bearer ' || svc_key)),

      ('drain-building-announcement-notifications',
       '*/2 * * * *',
       format(drain_tpl, fn_url || '/functions/v1/notify-building-announcement',
              'Bearer ' || svc_key))
    ) AS t(jobname, sched, cmd)
  LOOP
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = rec.jobname) THEN
      PERFORM cron.unschedule(rec.jobname);
    END IF;
    PERFORM cron.schedule(rec.jobname, rec.sched, rec.cmd);
  END LOOP;
END $$;

-- 4. Verification -------------------------------------------------------
--    deploy step greps this output; expects: cron jobs >= 6, vault secrets = 6.
SELECT 'cron jobs'      AS check, count(*)::text AS value FROM cron.job
UNION ALL
SELECT 'vault secrets', count(*)::text FROM vault.secrets WHERE name LIKE '%\_notify\_%'
UNION ALL
SELECT 'pg_cron ext',   COALESCE((SELECT extversion FROM pg_extension WHERE extname = 'pg_cron'), 'MISSING')
UNION ALL
SELECT 'pg_net ext',    COALESCE((SELECT extversion FROM pg_extension WHERE extname = 'pg_net'), 'MISSING');
