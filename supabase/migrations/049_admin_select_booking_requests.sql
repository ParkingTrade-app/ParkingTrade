-- ============================================================
-- Migration 049: Building admins can SELECT booking_requests
--                 in their building
--
-- Why:
--   Migration 013's SELECT policy on booking_requests is party-only
--   (borrower or lender apartment). Building admins could already
--   see `booking_issues` (047) and UPDATE bookings (036), but a
--   non-party admin could not read the underlying booking — so the
--   Flutter admin issues list could not join spot / window context,
--   and BookingDetailScreen failed to load for that admin.
--
-- Shape:
--   Same get_user_building_id() comparison as 036 (via the lender
--   apartment) plus role=admin AND status=approved, matching 047's
--   booking_issues SELECT. Existing party SELECT policy is unchanged;
--   Postgres ORs SELECT policies.
--
-- This does NOT grant INSERT/UPDATE/DELETE. Writes stay on the
-- existing party/admin UPDATE policies and Edge Functions / RPCs.
-- ============================================================

DROP POLICY IF EXISTS "Building admins can view booking requests in their building"
    ON booking_requests;

CREATE POLICY "Building admins can view booking requests in their building"
    ON booking_requests
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM profiles p
            WHERE  p.id = auth.uid()
              AND  p.role = 'admin'
              AND  p.status = 'approved'
              AND  get_user_building_id(p.id) = (
                       SELECT a.building_id
                       FROM   apartments a
                       WHERE  a.id = booking_requests.lender_apartment_id
                   )
        )
    );
