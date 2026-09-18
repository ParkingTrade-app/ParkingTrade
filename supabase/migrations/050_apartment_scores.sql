-- ============================================================
-- Migration 050: Building scoreboard (Roadmap 2.1, backend slice)
--
-- Compute per-apartment points from existing booking_requests +
-- booking_issues. No new write path — scores are a read-side view.
-- Clients never SELECT the view; they call get_building_leaderboard()
-- which re-checks the caller is an approved member of that building.
--
-- Weights (single tunable function — change here, not in the view)
-- ---------------------------------------------------------------
--   completed lend (status = completed, as lender)   +10
--   hour lent (duration of those completed lends)     +1 / hour
--   reciprocal swap (two completed bookings, same
--     window, opposite lender/borrower apartments)    +15 each side
--   upheld booking_issues against the accused party    -5
--     lender_did_not_vacate  → lender apartment
--     borrower_did_not_arrive / borrower_overstay → borrower
-- Open and dismissed issues do not score.
--
-- Why a view that bypasses RLS (security_invoker = false)
-- -------------------------------------------------------
-- booking_requests SELECT is party-only (013) + building-admin (049).
-- A security_invoker view would hide other apartments' lends and the
-- leaderboard would be empty for everyone except the parties. The view
-- is therefore owner-run (default), with SELECT revoked from
-- anon/authenticated. The SECURITY DEFINER RPC is the only client path.
--
-- Manual step this file does NOT perform: none (no cron, no Vault).
-- Flutter LeaderboardScreen / ScoreService are a later slice.
-- ============================================================

-- ─── 1. Tunable weights ─────────────────────────────────────
DROP FUNCTION IF EXISTS leaderboard_score_weights();
CREATE FUNCTION leaderboard_score_weights()
RETURNS TABLE (
    completed_lend INTEGER,
    hour_lent      NUMERIC,
    swap           INTEGER,
    upheld_issue   INTEGER
)
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
    SELECT
        10::integer  AS completed_lend,
        1::numeric   AS hour_lent,
        15::integer  AS swap,
        -5::integer  AS upheld_issue;
$$;

REVOKE ALL     ON FUNCTION leaderboard_score_weights() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION leaderboard_score_weights() TO postgres;
GRANT  EXECUTE ON FUNCTION leaderboard_score_weights() TO service_role;

COMMENT ON FUNCTION leaderboard_score_weights() IS
    'Roadmap 2.1 scoring weights. Edit this function body to retune; '
    'apartment_scores and get_building_leaderboard pick them up automatically.';


-- ─── 2. apartment_scores view ───────────────────────────────
DROP VIEW IF EXISTS apartment_scores;
CREATE VIEW apartment_scores
WITH (security_invoker = false)
AS
WITH w AS (
    SELECT * FROM leaderboard_score_weights()
),
lends AS (
    SELECT
        br.lender_apartment_id AS apartment_id,
        COUNT(*)::bigint AS completed_lends,
        ROUND(
            COALESCE(
                SUM(EXTRACT(EPOCH FROM (br.end_time - br.start_time)) / 3600.0),
                0
            )::numeric,
            2
        ) AS hours_lent
    FROM booking_requests br
    WHERE br.status = 'completed'
      AND br.lender_apartment_id IS NOT NULL
    GROUP BY br.lender_apartment_id
),
swaps AS (
    SELECT sides.apartment_id, COUNT(*)::bigint AS swaps_completed
    FROM booking_requests a
    JOIN booking_requests b
      ON b.lender_apartment_id   = a.borrower_apartment_id
     AND b.borrower_apartment_id = a.lender_apartment_id
     AND b.start_time = a.start_time
     AND b.end_time   = a.end_time
     AND b.status     = 'completed'
     AND a.id         < b.id
    CROSS JOIN LATERAL (
        VALUES (a.lender_apartment_id), (a.borrower_apartment_id)
    ) AS sides(apartment_id)
    WHERE a.status = 'completed'
      AND a.lender_apartment_id   IS NOT NULL
      AND a.borrower_apartment_id IS NOT NULL
    GROUP BY sides.apartment_id
),
penalties AS (
    SELECT
        CASE i.kind
            WHEN 'lender_did_not_vacate' THEN br.lender_apartment_id
            ELSE br.borrower_apartment_id
        END AS apartment_id,
        COUNT(*)::bigint AS upheld_issues
    FROM booking_issues i
    JOIN booking_requests br ON br.id = i.booking_id
    WHERE i.status = 'upheld'
    GROUP BY 1
)
SELECT
    apt.id         AS apartment_id,
    apt.building_id,
    apt.identifier AS apartment_identifier,
    COALESCE(l.completed_lends, 0)  AS completed_lends,
    COALESCE(l.hours_lent, 0)       AS hours_lent,
    COALESCE(s.swaps_completed, 0)  AS swaps_completed,
    COALESCE(p.upheld_issues, 0)    AS upheld_issues,
    ROUND(
        COALESCE(l.completed_lends, 0) * w.completed_lend
        + COALESCE(l.hours_lent, 0)    * w.hour_lent
        + COALESCE(s.swaps_completed, 0) * w.swap
        + COALESCE(p.upheld_issues, 0) * w.upheld_issue,
        2
    ) AS score
FROM apartments apt
CROSS JOIN w
LEFT JOIN lends     l ON l.apartment_id = apt.id
LEFT JOIN swaps     s ON s.apartment_id = apt.id
LEFT JOIN penalties p ON p.apartment_id = apt.id;

REVOKE ALL    ON apartment_scores FROM PUBLIC;
REVOKE ALL    ON apartment_scores FROM anon, authenticated;
GRANT  SELECT ON apartment_scores TO service_role;

COMMENT ON VIEW apartment_scores IS
    'Per-apartment leaderboard inputs + score (Roadmap 2.1). Not client-readable; '
    'query via get_building_leaderboard(building_id). Weights live in '
    'leaderboard_score_weights().';


-- ─── 3. get_building_leaderboard RPC ────────────────────────
-- SECURITY DEFINER so it can read apartment_scores (revoked from
-- authenticated). Self-securing: approved members may only query
-- their own building. Same GRANT/REVOKE + search_path shape as
-- get_unread_message_counts (033) / create_building_announcement (043).
DROP FUNCTION IF EXISTS get_building_leaderboard(UUID);
CREATE FUNCTION get_building_leaderboard(p_building_id UUID)
RETURNS TABLE (
    apartment_id         UUID,
    apartment_identifier TEXT,
    completed_lends      BIGINT,
    hours_lent           NUMERIC,
    swaps_completed      BIGINT,
    upheld_issues        BIGINT,
    score                NUMERIC,
    "rank"               BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller profiles;
    v_bid    UUID;
BEGIN
    SELECT * INTO v_caller FROM profiles WHERE id = auth.uid();
    IF NOT FOUND OR v_caller.status <> 'approved' THEN
        RAISE EXCEPTION 'only approved members can view the leaderboard'
            USING ERRCODE = '42501';
    END IF;

    v_bid := get_user_building_id(auth.uid());
    IF v_bid IS NULL OR p_building_id IS NULL OR v_bid <> p_building_id THEN
        RAISE EXCEPTION 'can only query your own building leaderboard'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        s.apartment_id,
        s.apartment_identifier,
        s.completed_lends,
        s.hours_lent,
        s.swaps_completed,
        s.upheld_issues,
        s.score,
        RANK() OVER (
            ORDER BY s.score DESC, s.apartment_identifier ASC
        )::bigint AS "rank"
    FROM apartment_scores s
    WHERE s.building_id = p_building_id
    ORDER BY 8 ASC, s.apartment_identifier ASC;
END;
$$;

REVOKE ALL     ON FUNCTION get_building_leaderboard(UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_building_leaderboard(UUID) TO authenticated;
GRANT  EXECUTE ON FUNCTION get_building_leaderboard(UUID) TO service_role;

COMMENT ON FUNCTION get_building_leaderboard(UUID) IS
    'Building leaderboard for p_building_id. SECURITY DEFINER; raises 42501 unless '
    'auth.uid() is an approved member of that building. Rank is 1-based, ties broken '
    'by apartment identifier.';
