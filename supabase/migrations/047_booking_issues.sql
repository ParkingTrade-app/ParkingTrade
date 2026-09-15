-- ============================================================
-- Migration 047: Booking issues (no-show / trust reports)
--
-- Booking-Trust epic, slice C. Recurring availability (046) is independent;
-- this slice records explicit trust events on a booking.
--
-- Why reports, not inferred no-shows
-- ----------------------------------
-- There is no GPS / garage-sensor signal. Auto-flagging every completed
-- booking would be noise. A resident who shows up to an occupied spot, or a
-- lender whose borrower never arrived / overstayed, files one report during
-- a bounded window. A building admin upholds or dismisses it. The booking
-- row is not rewritten — the window is usually already over; the issue row
-- is the durable trust record (and the future scoreboard input, Roadmap 2.1,
-- not in this epic).
--
-- Kinds (v1, locked):
--   lender_did_not_vacate  — borrower reports: spot still occupied on arrival
--   borrower_did_not_arrive — lender reports: borrower never showed
--   borrower_overstay       — lender reports: borrower did not leave by end
--
-- Window: now >= start_time AND now <= end_time + 24 hours
--         AND status IN ('approved', 'completed')
-- Party vs kind is enforced in report_booking_issue() (not a check constraint
-- — the reporter's apartment is known only at call time).
--
-- Compose path is a SECURITY DEFINER RPC (same shape as
-- create_building_announcement / review_join_request). Push is async via
-- the outbox below — the RPC never holds the service-role key and never
-- makes HTTP.
--
-- Completion grace: complete_expired_bookings() now waits until
-- end_time + 2 hours so a lender can still file an overstay before the
-- row flips to completed. Reports remain valid for 24h after end_time
-- even once completed.
--
-- Manual step this file does NOT perform
-- --------------------------------------
-- pg_cron drain of booking_issue_notifications, Vault secrets for the
-- real-time webhook (048). Both live in supabase/bootstrap/bootstrap.sql.
-- ============================================================

DO $$ BEGIN
    CREATE TYPE booking_issue_kind AS ENUM (
        'lender_did_not_vacate',
        'borrower_did_not_arrive',
        'borrower_overstay'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE booking_issue_status AS ENUM ('open', 'upheld', 'dismissed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ─── 1. Domain table ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS booking_issues (
    id                     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    booking_id             UUID NOT NULL REFERENCES booking_requests(id) ON DELETE CASCADE,
    building_id            UUID NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
    reporter_profile_id    UUID REFERENCES profiles(id) ON DELETE SET NULL,
    reporter_apartment_id  UUID NOT NULL REFERENCES apartments(id) ON DELETE CASCADE,
    kind                   booking_issue_kind   NOT NULL,
    status                 booking_issue_status NOT NULL DEFAULT 'open',
    notes                  TEXT CHECK (notes IS NULL OR char_length(btrim(notes)) BETWEEN 1 AND 500),
    resolved_by            UUID REFERENCES profiles(id) ON DELETE SET NULL,
    resolved_at            TIMESTAMPTZ,
    resolution_notes       TEXT CHECK (resolution_notes IS NULL OR char_length(btrim(resolution_notes)) BETWEEN 1 AND 500),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_booking_issues_booking
    ON booking_issues (booking_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_booking_issues_building_status
    ON booking_issues (building_id, status, created_at DESC);

-- One open report per apartment per booking — either party can file once;
-- they cannot stack duplicates while the first is still open.
CREATE UNIQUE INDEX IF NOT EXISTS uq_booking_issues_open_per_apartment
    ON booking_issues (booking_id, reporter_apartment_id)
    WHERE status = 'open';

DROP TRIGGER IF EXISTS update_booking_issues_updated_at ON booking_issues;
CREATE TRIGGER update_booking_issues_updated_at
    BEFORE UPDATE ON booking_issues
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

ALTER TABLE booking_issues ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Parties and building admins can view booking issues" ON booking_issues;
CREATE POLICY "Parties and building admins can view booking issues"
    ON booking_issues
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM profiles p
            WHERE p.id = auth.uid()
              AND p.apartment_id = booking_issues.reporter_apartment_id
        )
        OR EXISTS (
            SELECT 1
            FROM   booking_requests br
            JOIN   profiles p ON p.id = auth.uid()
            WHERE  br.id = booking_issues.booking_id
              AND  p.apartment_id IN (br.borrower_apartment_id, br.lender_apartment_id)
        )
        OR EXISTS (
            SELECT 1 FROM profiles p
            WHERE p.id = auth.uid()
              AND p.role = 'admin'
              AND p.status = 'approved'
              AND get_user_building_id(p.id) = booking_issues.building_id
        )
    );

-- No INSERT / UPDATE / DELETE policies: writes go through the RPCs below.

COMMENT ON TABLE booking_issues IS
    'Resident-filed trust reports on a booking (no-show / occupied / overstay). '
    'Written only by report_booking_issue / resolve_booking_issue. Future '
    'apartment_scores (Roadmap 2.1) should count status = upheld.';

-- ─── 2. Audit FK (nullable, like join_request_id in 041) ─────
ALTER TABLE admin_audit_log
    ADD COLUMN IF NOT EXISTS booking_issue_id UUID REFERENCES booking_issues(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_admin_audit_log_booking_issue
    ON admin_audit_log (booking_issue_id)
    WHERE booking_issue_id IS NOT NULL;

-- ─── 3. Completion grace (2 hours after end_time) ────────────
CREATE OR REPLACE FUNCTION complete_expired_bookings()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    affected INTEGER;
BEGIN
    UPDATE booking_requests
    SET status = 'completed',
        updated_at = NOW()
    WHERE status = 'approved'
      AND end_time < NOW() - INTERVAL '2 hours';

    GET DIAGNOSTICS affected = ROW_COUNT;
    RETURN affected;
END;
$$;

COMMENT ON FUNCTION complete_expired_bookings() IS
    'Marks approved bookings completed once end_time + 2 hours has passed '
    '(grace so a lender can still file borrower_overstay). Reports remain '
    'valid for 24 hours after end_time even on completed rows.';

-- ─── 4. Report RPC ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION report_booking_issue(
    p_booking_id UUID,
    p_kind       TEXT,
    p_notes      TEXT DEFAULT NULL
)
RETURNS booking_issues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller   profiles;
    v_booking  booking_requests;
    v_kind     booking_issue_kind;
    v_notes    TEXT := NULLIF(btrim(COALESCE(p_notes, '')), '');
    v_building UUID;
    v_row      booking_issues;
    v_is_borrower BOOLEAN;
    v_is_lender   BOOLEAN;
BEGIN
    BEGIN
        v_kind := p_kind::booking_issue_kind;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'invalid issue kind: %', p_kind USING ERRCODE = '22023';
    END;

    IF v_notes IS NOT NULL AND char_length(v_notes) > 500 THEN
        RAISE EXCEPTION 'notes must be at most 500 characters' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_caller FROM profiles WHERE id = auth.uid();
    IF NOT FOUND OR v_caller.status <> 'approved' OR v_caller.apartment_id IS NULL THEN
        RAISE EXCEPTION 'only an approved building member can report a booking issue' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_booking FROM booking_requests WHERE id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'booking not found' USING ERRCODE = 'P0002';
    END IF;

    IF v_booking.status NOT IN ('approved', 'completed') THEN
        RAISE EXCEPTION 'can only report on an approved or completed booking' USING ERRCODE = '22023';
    END IF;

    IF NOW() < v_booking.start_time OR NOW() > v_booking.end_time + INTERVAL '24 hours' THEN
        RAISE EXCEPTION 'report window is start_time through end_time + 24 hours' USING ERRCODE = '22023';
    END IF;

    v_is_borrower := v_caller.apartment_id = v_booking.borrower_apartment_id;
    v_is_lender   := v_caller.apartment_id = v_booking.lender_apartment_id;

    IF NOT v_is_borrower AND NOT v_is_lender THEN
        RAISE EXCEPTION 'only a booking party can report an issue' USING ERRCODE = '42501';
    END IF;

    IF v_kind = 'lender_did_not_vacate' AND NOT v_is_borrower THEN
        RAISE EXCEPTION 'only the borrower apartment can report lender_did_not_vacate' USING ERRCODE = '42501';
    END IF;
    IF v_kind IN ('borrower_did_not_arrive', 'borrower_overstay') AND NOT v_is_lender THEN
        RAISE EXCEPTION 'only the lender apartment can report %', v_kind USING ERRCODE = '42501';
    END IF;

    SELECT COALESCE(ps.building_id, apt.building_id) INTO v_building
    FROM   parking_spots ps
    JOIN   apartments apt ON apt.id = ps.apartment_id
    WHERE  ps.id = v_booking.spot_id;

    IF v_building IS NULL THEN
        RAISE EXCEPTION 'could not resolve building for booking' USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO booking_issues (
        booking_id, building_id, reporter_profile_id, reporter_apartment_id,
        kind, notes
    ) VALUES (
        v_booking.id, v_building, v_caller.id, v_caller.apartment_id,
        v_kind, v_notes
    )
    RETURNING * INTO v_row;

    INSERT INTO admin_audit_log
        (admin_id, target_id, building_id, action, old_status, new_status, booking_issue_id)
    VALUES
        (NULL, v_caller.id, v_building, 'booking_issue_report', NULL, 'open', v_row.id);

    RETURN v_row;
END;
$$;

REVOKE ALL     ON FUNCTION report_booking_issue(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION report_booking_issue(UUID, TEXT, TEXT) TO authenticated;
GRANT  EXECUTE ON FUNCTION report_booking_issue(UUID, TEXT, TEXT) TO service_role;

-- ─── 5. Resolve RPC ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION resolve_booking_issue(
    p_issue_id UUID,
    p_action   TEXT,               -- 'upheld' | 'dismissed'
    p_notes    TEXT DEFAULT NULL
)
RETURNS booking_issues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin  profiles;
    v_bid    UUID;
    v_row    booking_issues;
    v_action TEXT := lower(btrim(COALESCE(p_action, '')));
    v_notes  TEXT := NULLIF(btrim(COALESCE(p_notes, '')), '');
BEGIN
    IF v_action NOT IN ('upheld', 'dismissed') THEN
        RAISE EXCEPTION 'action must be upheld or dismissed' USING ERRCODE = '22023';
    END IF;

    IF v_notes IS NOT NULL AND char_length(v_notes) > 500 THEN
        RAISE EXCEPTION 'resolution notes must be at most 500 characters' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_admin FROM profiles WHERE id = auth.uid();
    IF NOT FOUND OR v_admin.role <> 'admin' OR v_admin.status <> 'approved' THEN
        RAISE EXCEPTION 'only building admins can resolve booking issues' USING ERRCODE = '42501';
    END IF;

    v_bid := get_user_building_id(auth.uid());
    IF v_bid IS NULL THEN
        RAISE EXCEPTION 'admin has no building assigned' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_row FROM booking_issues WHERE id = p_issue_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'booking issue not found' USING ERRCODE = 'P0002';
    END IF;

    IF v_row.building_id <> v_bid THEN
        RAISE EXCEPTION 'booking issue is not in your building' USING ERRCODE = '42501';
    END IF;

    IF v_row.status <> 'open' THEN
        RAISE EXCEPTION 'booking issue is already %', v_row.status USING ERRCODE = '22023';
    END IF;

    UPDATE booking_issues
    SET    status           = v_action::booking_issue_status,
           resolved_by      = v_admin.id,
           resolved_at      = NOW(),
           resolution_notes = v_notes
    WHERE  id = v_row.id
    RETURNING * INTO v_row;

    INSERT INTO admin_audit_log
        (admin_id, target_id, building_id, action, old_status, new_status, booking_issue_id)
    VALUES
        (v_admin.id, v_row.reporter_profile_id, v_bid,
         'booking_issue_' || v_action, 'open', v_action, v_row.id);

    RETURN v_row;
END;
$$;

REVOKE ALL     ON FUNCTION resolve_booking_issue(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION resolve_booking_issue(UUID, TEXT, TEXT) TO authenticated;
GRANT  EXECUTE ON FUNCTION resolve_booking_issue(UUID, TEXT, TEXT) TO service_role;

COMMENT ON FUNCTION report_booking_issue(UUID, TEXT, TEXT) IS
    'Booking party files a trust report during start_time .. end_time+24h on an '
    'approved/completed booking. Kind is party-gated. Enqueues an outbox row.';
COMMENT ON FUNCTION resolve_booking_issue(UUID, TEXT, TEXT) IS
    'Building admin upholds or dismisses an open booking_issues row. Does not '
    'rewrite the booking. Enqueues a resolved outbox row.';

-- ─── 6. Delivery outbox ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS booking_issue_notifications (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    issue_id   UUID NOT NULL REFERENCES booking_issues(id) ON DELETE CASCADE,
    event      TEXT NOT NULL CHECK (event IN ('reported', 'resolved')),
    status     waitlist_notification_status NOT NULL DEFAULT 'pending',
    attempts   INTEGER NOT NULL DEFAULT 0,
    recipients INTEGER,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sent_at    TIMESTAMPTZ,
    UNIQUE (issue_id, event)
);

CREATE INDEX IF NOT EXISTS idx_booking_issue_notifications_pending
    ON booking_issue_notifications (status, created_at)
    WHERE status = 'pending';

ALTER TABLE booking_issue_notifications ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE booking_issue_notifications IS
    'Outbox of pending push notifications for booking_issues (reported / resolved). '
    'Drained by notify-booking-issue. Service-role only.';

CREATE OR REPLACE FUNCTION trg_enqueue_booking_issue_notification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO booking_issue_notifications (issue_id, event)
        VALUES (NEW.id, 'reported')
        ON CONFLICT (issue_id, event) DO NOTHING;
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE'
       AND OLD.status = 'open'
       AND NEW.status IN ('upheld', 'dismissed') THEN
        INSERT INTO booking_issue_notifications (issue_id, event)
        VALUES (NEW.id, 'resolved')
        ON CONFLICT (issue_id, event) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS booking_issue_enqueue_on_insert ON booking_issues;
CREATE TRIGGER booking_issue_enqueue_on_insert
    AFTER INSERT ON booking_issues
    FOR EACH ROW
    EXECUTE FUNCTION trg_enqueue_booking_issue_notification();

DROP TRIGGER IF EXISTS booking_issue_enqueue_on_resolve ON booking_issues;
CREATE TRIGGER booking_issue_enqueue_on_resolve
    AFTER UPDATE OF status ON booking_issues
    FOR EACH ROW
    EXECUTE FUNCTION trg_enqueue_booking_issue_notification();
