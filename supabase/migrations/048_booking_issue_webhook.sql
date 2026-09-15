-- ============================================================
-- Migration 048: Real-time delivery for the booking-issue outbox
--
-- Identical Vault + pg_net webhook pattern as 039 / 040 / 044.
-- See migration 039's header for the full rationale (TG_ARGV cannot
-- hold a runtime URL/key; ALTER DATABASE SET needs superuser; Vault
-- is the postgres-role-writable store).
--
-- Feature-scoped secrets:
--   issue_notify_functions_base_url
--   issue_notify_service_role_key
-- Opt-in, no default, every environment including local — this
-- migration creates neither secret. Missing secrets ⇒ NOTICE and
-- return; the INSERT is unaffected. E2E drains via
-- f.edgeAsService('notify-booking-issue', ...).
--
-- ── One-time activation (SQL editor, never commit the values) ─
--   Local:
--     SELECT vault.create_secret('http://api.supabase.internal:8000', 'issue_notify_functions_base_url');
--     SELECT vault.create_secret('<service_role from `supabase status`>', 'issue_notify_service_role_key');
--   Hosted:
--     SELECT vault.create_secret('https://<project-ref>.supabase.co', 'issue_notify_functions_base_url');
--     SELECT vault.create_secret('<service_role secret>', 'issue_notify_service_role_key');
--
-- Keep the pg_cron drain (bootstrap.sql) running as the durability backstop.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION trg_notify_booking_issue_webhook()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    base_url   TEXT;
    svc_key    TEXT;
    request_id BIGINT;
BEGIN
    SELECT decrypted_secret INTO base_url
    FROM   vault.decrypted_secrets
    WHERE  name = 'issue_notify_functions_base_url';

    SELECT decrypted_secret INTO svc_key
    FROM   vault.decrypted_secrets
    WHERE  name = 'issue_notify_service_role_key';

    IF base_url IS NULL OR base_url = '' OR svc_key IS NULL OR svc_key = '' THEN
        RAISE NOTICE 'trg_notify_booking_issue_webhook: vault secrets issue_notify_functions_base_url / issue_notify_service_role_key not configured — skipping real-time delivery for outbox row %. It remains pending for the periodic drain.', NEW.id;
        RETURN NEW;
    END IF;

    SELECT http_post INTO request_id FROM net.http_post(
        url     := base_url || '/functions/v1/notify-booking-issue',
        body    := jsonb_build_object('issue_id', NEW.issue_id, 'event', NEW.event),
        headers := jsonb_build_object(
                       'Content-Type', 'application/json',
                       'Authorization', 'Bearer ' || svc_key
                   ),
        timeout_milliseconds := 5000
    );

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS booking_issue_notify_webhook ON booking_issue_notifications;
CREATE TRIGGER booking_issue_notify_webhook
    AFTER INSERT ON booking_issue_notifications
    FOR EACH ROW
    EXECUTE FUNCTION trg_notify_booking_issue_webhook();

COMMENT ON FUNCTION trg_notify_booking_issue_webhook() IS
    'Fires notify-booking-issue immediately via pg_net on outbox insert. Reads '
    'issue_notify_functions_base_url / issue_notify_service_role_key from Vault '
    'and no-ops if either is missing. pg_cron drain remains the durable fallback.';
