-- ============================================================
-- Migration 046: Recurring availability — SQL is the source of truth
--
-- Context
-- -------
-- Migration 004 added `is_recurring` + `recurring_pattern` on
-- `spot_availability_periods`. The Flutter client already writes weekly
-- templates (JSON `{"type":"weekly","days":["MON",...],"until":"..."}`
-- or legacy keywords `daily`/`weekly`/`weekdays`/`weekends`) and expands
-- them in Dart (`ParkingSpotService.expandRecurringPeriods`).
--
-- The database did not. Consequences:
--   * `trg_waitlist_on_availability` (032) overlapped waitlist entries
--     against the template's *anchor* start/end only — a "every Monday
--     10–12" row never matched a waitlist for next Monday.
--   * `create-booking-request` never checked availability at all.
--
-- This migration does NOT materialize occurrence rows. One template stays
-- the domain object. Expansion happens in SQL so Edge Functions, waitlist
-- triggers, and a periodic backfill share one implementation.
--
-- `recurring_pattern` stays TEXT on purpose: the Flutter client currently
-- inserts a JSON-encoded *string*. Promoting the column to JSONB without
-- a client change would store a JSON scalar string, and `->>'type'` would
-- be NULL. A later UI PR can send a real JSON object; the parser below
-- already accepts both a JSON object string and a legacy keyword.
--
-- Manual step this file does NOT perform
-- --------------------------------------
-- Schedule `match_waitlist_against_upcoming_availability()` via pg_cron
-- (templates published before a waiter joined would otherwise sit unmatched
-- until the next occurrence is "re-published"). Added to
-- supabase/bootstrap/bootstrap.sql as job `match-waitlist-upcoming`.
-- ============================================================

-- ─── 1. Parse a TEXT pattern into a JSONB object ─────────────
-- Always returns a JSONB object with at least {"type": "..."}.
CREATE OR REPLACE FUNCTION parse_recurring_pattern(raw TEXT)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
    trimmed TEXT;
    parsed  JSONB;
BEGIN
    IF raw IS NULL THEN
        RETURN jsonb_build_object('type', 'weekly');
    END IF;

    trimmed := btrim(raw);
    IF trimmed = '' THEN
        RETURN jsonb_build_object('type', 'weekly');
    END IF;

    IF left(trimmed, 1) = '{' THEN
        BEGIN
            parsed := trimmed::jsonb;
            IF jsonb_typeof(parsed) = 'object' THEN
                IF parsed->>'type' IS NULL OR parsed->>'type' = '' THEN
                    parsed := parsed || jsonb_build_object('type', 'weekly');
                END IF;
                RETURN parsed;
            END IF;
        EXCEPTION WHEN invalid_text_representation OR syntax_error THEN
            NULL;
        END;
    END IF;

    IF lower(trimmed) IN ('daily', 'weekly', 'weekdays', 'weekends') THEN
        RETURN jsonb_build_object('type', lower(trimmed));
    END IF;

    RETURN jsonb_build_object('type', 'weekly');
END;
$$;

-- ─── 2. Expand templates into concrete occurrences ───────────
-- Semantics match ParkingSpotService.expandRecurringPeriods:
--   * non-recurring rows returned as-is if they overlap [p_from, p_to)
--   * recurring rows iterated day-by-day in UTC from the template's
--     start date, using the template duration, until p_to (or pattern
--     `until`, whichever is sooner)
--   * range longer than 90 days is clamped (bad-call guard)
CREATE OR REPLACE FUNCTION expand_availability_occurrences(
    p_spot_id UUID,
    p_from    TIMESTAMPTZ,
    p_to      TIMESTAMPTZ
)
RETURNS TABLE (
    period_id  UUID,
    start_time TIMESTAMPTZ,
    end_time   TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    v_from     TIMESTAMPTZ := p_from;
    v_to       TIMESTAMPTZ := p_to;
    rec        RECORD;
    pattern    JSONB;
    v_type     TEXT;
    v_until    TIMESTAMPTZ;
    v_days     INT[];
    v_duration INTERVAL;
    v_cursor   TIMESTAMPTZ;
    v_stop     TIMESTAMPTZ;
    v_iso      INT;
    v_include  BOOLEAN;
    v_end      TIMESTAMPTZ;
    code       TEXT;
    d          INT;
BEGIN
    IF v_from IS NULL OR v_to IS NULL OR v_to <= v_from THEN
        RETURN;
    END IF;
    IF v_to > v_from + INTERVAL '90 days' THEN
        v_to := v_from + INTERVAL '90 days';
    END IF;

    FOR rec IN
        SELECT sap.id, sap.start_time AS s, sap.end_time AS e,
               sap.is_recurring, sap.recurring_pattern
        FROM   spot_availability_periods sap
        WHERE  sap.spot_id = p_spot_id
    LOOP
        IF NOT rec.is_recurring THEN
            IF rec.s < v_to AND rec.e > v_from THEN
                period_id  := rec.id;
                start_time := rec.s;
                end_time   := rec.e;
                RETURN NEXT;
            END IF;
            CONTINUE;
        END IF;

        pattern := parse_recurring_pattern(rec.recurring_pattern);
        v_type  := lower(COALESCE(pattern->>'type', 'weekly'));
        v_until := NULL;
        IF pattern ? 'until' AND NULLIF(pattern->>'until', '') IS NOT NULL THEN
            BEGIN
                v_until := (pattern->>'until')::timestamptz;
            EXCEPTION WHEN others THEN
                v_until := NULL;
            END;
        END IF;

        v_days := NULL;
        IF jsonb_typeof(pattern->'days') = 'array' THEN
            v_days := ARRAY[]::INT[];
            FOR code IN SELECT jsonb_array_elements_text(pattern->'days')
            LOOP
                d := CASE upper(code)
                    WHEN 'MON' THEN 1
                    WHEN 'TUE' THEN 2
                    WHEN 'WED' THEN 3
                    WHEN 'THU' THEN 4
                    WHEN 'FRI' THEN 5
                    WHEN 'SAT' THEN 6
                    WHEN 'SUN' THEN 7
                    ELSE NULL
                END;
                IF d IS NOT NULL THEN
                    v_days := array_append(v_days, d);
                END IF;
            END LOOP;
            IF array_length(v_days, 1) IS NULL THEN
                v_days := NULL;
            END IF;
        END IF;

        v_duration := rec.e - rec.s;
        -- Anchor at the template's UTC date + UTC time-of-day (matches Dart,
        -- which stores wall-clock as UTC).
        v_cursor := (
            date_trunc('day', rec.s AT TIME ZONE 'UTC')
            + (rec.s AT TIME ZONE 'UTC')::time
        ) AT TIME ZONE 'UTC';

        v_stop := v_to;
        IF v_until IS NOT NULL AND v_until < v_stop THEN
            v_stop := v_until;
        END IF;

        WHILE v_cursor <= v_stop LOOP
            v_iso := EXTRACT(ISODOW FROM v_cursor AT TIME ZONE 'UTC')::INT;
            v_include := CASE v_type
                WHEN 'daily'    THEN TRUE
                WHEN 'weekdays' THEN v_iso BETWEEN 1 AND 5
                WHEN 'weekends' THEN v_iso IN (6, 7)
                WHEN 'weekly'   THEN
                    CASE
                        WHEN v_days IS NOT NULL THEN v_iso = ANY (v_days)
                        ELSE v_iso = EXTRACT(ISODOW FROM rec.s AT TIME ZONE 'UTC')::INT
                    END
                ELSE v_iso = EXTRACT(ISODOW FROM rec.s AT TIME ZONE 'UTC')::INT
            END;

            IF v_include THEN
                v_end := v_cursor + v_duration;
                IF v_cursor < v_to AND v_end > v_from THEN
                    period_id  := rec.id;
                    start_time := v_cursor;
                    end_time   := v_end;
                    RETURN NEXT;
                END IF;
            END IF;

            v_cursor := v_cursor + INTERVAL '1 day';
        END LOOP;
    END LOOP;
END;
$$;

-- ─── 3. Does this spot accept a requested window? ────────────
-- Overlap (not containment) — matches specs.md §3 and the Dart
-- `isSpotAvailable` check. Zero periods ⇒ always available
-- (backward compatible).
CREATE OR REPLACE FUNCTION spot_availability_overlaps(
    p_spot_id UUID,
    p_start   TIMESTAMPTZ,
    p_end     TIMESTAMPTZ
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count INT;
BEGIN
    IF p_spot_id IS NULL OR p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RETURN FALSE;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM   spot_availability_periods
    WHERE  spot_id = p_spot_id;

    IF v_count = 0 THEN
        RETURN TRUE;
    END IF;

    RETURN EXISTS (
        SELECT 1
        FROM   expand_availability_occurrences(
                   p_spot_id,
                   p_start - INTERVAL '1 day',
                   p_end   + INTERVAL '1 day'
               ) occ
        WHERE  occ.start_time < p_end
          AND  occ.end_time   > p_start
    );
END;
$$;

-- ─── 4. Waitlist match on publish: expand recurring templates ─
CREATE OR REPLACE FUNCTION trg_waitlist_on_availability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    occ RECORD;
BEGIN
    IF NOT NEW.is_recurring THEN
        PERFORM match_waitlist_entries(NEW.spot_id, NEW.start_time, NEW.end_time);
        RETURN NEW;
    END IF;

    -- AFTER INSERT: NEW is already visible to expand_availability_occurrences.
    FOR occ IN
        SELECT e.start_time, e.end_time
        FROM   expand_availability_occurrences(
                   NEW.spot_id,
                   GREATEST(NEW.start_time, NOW() - INTERVAL '1 day'),
                   NOW() + INTERVAL '30 days'
               ) e
        WHERE  e.period_id = NEW.id
    LOOP
        PERFORM match_waitlist_entries(NEW.spot_id, occ.start_time, occ.end_time);
    END LOOP;

    RETURN NEW;
END;
$$;

-- ─── 5. Periodic backfill: waiters who joined AFTER publish ───
-- Informational matching (same as 032): does not inspect bookings.
CREATE OR REPLACE FUNCTION match_waitlist_against_upcoming_availability()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    affected INTEGER;
BEGIN
    UPDATE spot_waitlist sw
    SET    status     = 'matched',
           matched_at = NOW(),
           updated_at = NOW()
    WHERE  sw.status = 'waiting'
      AND  EXISTS (
            SELECT 1
            FROM   expand_availability_occurrences(
                       sw.spot_id,
                       sw.desired_start - INTERVAL '1 day',
                       sw.desired_end   + INTERVAL '1 day'
                   ) occ
            WHERE  occ.start_time < sw.desired_end
              AND  occ.end_time   > sw.desired_start
          );

    GET DIAGNOSTICS affected = ROW_COUNT;
    RETURN affected;
END;
$$;

-- ─── Grants ──────────────────────────────────────────────────
-- 030's default privileges give EXECUTE to service_role for new
-- functions. Authenticated needs these two for future client use
-- and for E2E (residents call create-booking-request, which uses
-- the service role; the waitlist backfill is service-role / cron).
GRANT EXECUTE ON FUNCTION parse_recurring_pattern(TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION expand_availability_occurrences(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION spot_availability_overlaps(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION match_waitlist_against_upcoming_availability() TO service_role;

COMMENT ON FUNCTION expand_availability_occurrences(UUID, TIMESTAMPTZ, TIMESTAMPTZ) IS
    'Expand one-shot and recurring spot_availability_periods into concrete [start,end) instances overlapping [p_from, p_to). Range clamped to 90 days. UTC day-walk matches ParkingSpotService.expandRecurringPeriods.';
COMMENT ON FUNCTION spot_availability_overlaps(UUID, TIMESTAMPTZ, TIMESTAMPTZ) IS
    'True if the spot has no periods (always-available) or any expanded occurrence overlaps [p_start, p_end). Called by create-booking-request.';
COMMENT ON FUNCTION match_waitlist_against_upcoming_availability() IS
    'Marks waiting waitlist entries matched when any expanded occurrence overlaps their desired window. pg_cron backstop for waiters who join after a recurring template was published. Does not inspect bookings — matching is informational (032).';
