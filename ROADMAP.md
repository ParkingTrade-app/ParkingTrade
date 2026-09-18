# ParkingTrade — Feature Roadmap & Implementation Prompts

Each feature below includes scope notes grounded in the current codebase and a ready-to-paste prompt for Claude Code. Recommended order: Phase 1 → 3.

**Current state (for context):** per-booking chat already exists (`chat_service.dart` + `send-chat-message` edge function + Realtime). FCM tokens are stored (`011_user_fcm_tokens.sql`) and push is wired through `notification_service.dart`. Spot availability uses time-period windows (`spot_availability_periods`). There is no queue/waitlist concept, no points system, and no recurring bookings yet.

---

## Phase 1 — Core matching improvements

### 1.1 Waitlist / queue for unavailable spots (prerequisite for #2)

**Status: ✅ Implemented (2026-07-07).** Delivered: migration `032_spot_waitlist.sql` (table + RLS + match triggers on availability publish and approved-booking cancel + expiry function), `SpotWaitlistEntry` model, `WaitlistService`, "Join waitlist" card in the request-spot screen, "Waitlist" section in My bookings, EN/HE translations, and E2E scenario `11-waitlist.ts`. To ship: `supabase db push`, then run `flutter analyze` + e2e suite. Optionally schedule `expire_waitlist_entries()` via pg_cron (see migration comment).

You can't notify "tenants in queue" without a queue. Residents join a waitlist for a spot/time-range; when a matching availability period opens or a booking is cancelled, queued residents are matched FIFO.

**Prompt:**
```
Add a waitlist feature to ParkingTrade. Create a migration for a `spot_waitlist` table
(id, spot_id, requester_apartment_id, created_by_profile_id, desired_start, desired_end,
status: waiting|matched|expired|cancelled, created_at) with RLS scoped to the same
building, following the patterns in migrations 013/015. Add a `join_waitlist` flow:
when a resident tries to book a spot with no availability, offer "notify me when
available". Create a Postgres trigger (or extend the relevant edge functions) so that
when a new spot_availability_period is inserted or a booking is cancelled, overlapping
waitlist entries are marked `matched`. Add a WaitlistService in lib/services and a
minimal UI: a "Join waitlist" button on the spot screen and a "My waitlist" section in
bookings. Follow existing service/model conventions. Write E2E coverage in e2e/
mirroring the existing booking lifecycle scenarios.
```

### 1.2 Chat between tenants on match (requested #1)

**Status: ✅ Implemented (2026-07-10).** Chat was already permitted on `pending` bookings — the messages RLS (migration 013) and the `send-chat-message` participant check key off apartment membership, not booking status, and the booking detail screen surfaces "Open chat" for every status (reached from the `booking_request` push via `navigation_service.dart`). The new work is unread tracking: migration `033_message_read_receipts.sql` (per-profile `message_read_receipts` table + `mark_booking_read(uuid)` + `get_unread_message_counts()` RPCs), unread badges on the bookings list and the detail chat button, mark-read wired into `ChatScreen`, and E2E scenario `12-chat-coordination.ts`. To ship: `supabase db push` (no edge-function change). Verified via PGlite (migration + RPC logic) and `tsc` (e2e).

Chat exists per booking. The gap: open/surface a chat as soon as a match happens (booking request created or waitlist match), before approval, so tenants can coordinate.

**Prompt:**
```
ParkingTrade already has per-booking chat (lib/services/chat_service.dart, messages
table, send-chat-message edge function with push). Extend it so chat becomes available
at match time, not only after approval: 1) allow messages on bookings in `pending`
status — check RLS in 015_rls_policies.sql and the participant check in
send-chat-message and relax them to include pending bookings between the two
apartments; 2) when create-booking-request succeeds, send a push notification to the
lender apartment with a deep link that opens the chat screen for that booking
(navigation_service.dart already handles notification taps — verify the route); 3) add
an unread-message badge on the bookings list using a `last_read_at` column per
participant (new migration). Update the E2E chat scenarios accordingly.
```

### 1.3 Push notifications for tenants in queue (requested #2)

**Status: ✅ Implemented (2026-07-10).** Delivered: migration `034_waitlist_match_notifications.sql` (a durable `waitlist_match_notifications` outbox + enqueue trigger on `waiting → matched`, covering both of migration 032's match paths), edge function `notify-waitlist-match` (service-role only; drains the outbox, pushes every opted-in approved profile of the requester apartment, retries up to 5×), FCM dead-token pruning added to `_shared/push.ts` on `UNREGISTERED`/`INVALID_ARGUMENT`, a `waitlist_match` deep link in `navigation_service.dart` that opens the spots list with the matched window pre-filled (new `AvailableSpotsScreen.initialFilterStart`), and E2E scenario `13-waitlist-notifications.ts`.

**Design note:** an outbox is used instead of a pg_net call straight from the trigger, so the service-role key stays out of the database, a slow/failed HTTP call can't stall the matching transaction, delivery is retryable and auditable, and the whole path is assertable in E2E without a live FCM setup. Schedule the drain via pg_cron or point a Database Webhook at the function (both documented in the migration header). To ship: `supabase db push` + `supabase functions deploy notify-waitlist-match send-chat-message create-booking-request approve-booking` (the last three pick up the shared push change).

**Prompt:**
```
Building on the spot_waitlist table: when a waitlist entry transitions to `matched`,
send an FCM push to all profiles of the requester apartment. Follow the exact push
pattern used in the send-chat-message edge function (_shared utilities, user_fcm_tokens
from migration 011). Implement as a new edge function `notify-waitlist-match` invoked
by a database webhook (or pg_net trigger) on waitlist status change. The notification
should deep-link to the spot's booking screen with the matched time range pre-filled.
Handle token cleanup on FCM "unregistered" errors as done elsewhere. Add an E2E
scenario: user A holds a spot, user B joins waitlist, A cancels, assert B's waitlist
entry is matched and a notification row/log is produced.
```

---

## Phase 2 — Engagement

### 2.1 Scoreboard with leading tenants (requested #3)

**Status: ⏳ Backend slice implemented (migration 050).** `apartment_scores` view + `get_building_leaderboard(building_id)` SECURITY DEFINER RPC (own-building only). Weights in `leaderboard_score_weights()`: completed lend +10, hour lent +1, reciprocal completed swap +15, upheld `booking_issues` −5. E2E `20-building-scoreboard.ts`. Remaining: Flutter `LeaderboardScreen` + `ScoreService` (not this PR).

Points for lending spots; leaderboard per building. Compute from existing data first (no new write paths), then display.

**Prompt:**
```
Add a building leaderboard to ParkingTrade. Create a Postgres view (or materialized
view refreshed daily) `apartment_scores` that aggregates per apartment within a
building: completed bookings as lender (+10 each), total hours lent (+1/hour), swaps
completed (+15), no-show/cancellation after approval (-5). Base it on the
booking_requests table statuses (see 008_auto_complete_bookings.sql for the completed
transition). Expose it via a SECURITY DEFINER RPC `get_building_leaderboard(building_id)`
with a same-building membership check, following the RPC patterns in migration 023.
Build a LeaderboardScreen under lib/screens/building/ showing rank, apartment label,
points, and a badge for top 3, with the current user's apartment highlighted. Add a
ScoreService in lib/services. Keep scoring weights in one SQL constant block so they're
easy to tune. Add E2E assertions on the RPC output after the seed script runs.
```

### 2.2 Automatic / recurring future swaps (requested #4 — Eden's idea)

Standing swap: "my spot ↔ your spot, every Sun–Thu 08:00–18:00" auto-creates bookings each period.

**Prompt:**
```
Implement recurring swap agreements in ParkingTrade. New migration: `swap_agreements`
table (id, spot_a_id, spot_b_id, apartment_a_id, apartment_b_id, days_of_week int[],
start_time time, end_time time, valid_from date, valid_until date nullable, status:
proposed|active|paused|ended, created_at) with same-building RLS. Flow: apartment A
proposes via new edge function `propose-swap`, apartment B accepts via `respond-swap`
(reuse the auth/authorization structure of create-booking-request and approve-booking).
When active, a scheduled job (pg_cron, like 008_auto_complete_bookings.sql if it uses
cron — check and follow that mechanism) materializes the next 14 days of bookings as
pre-approved booking_requests in both directions, respecting the overlap constraint
from migration 002 (skip and notify on conflict). Either side can pause/end; ending
cancels future materialized bookings only. UI: "Set up recurring swap" entry point on
the spot detail screen and a management screen under lib/screens/bookings/. Push
notifications on propose/accept/conflict via the existing FCM pattern. Add full E2E
lifecycle coverage: propose → accept → bookings materialized → pause → end.
```

---

## Phase 3 — Suggested additions (my proposals)

### 3.1 No-show reporting & trust

**Prompt:**
```
Add no-show reporting: a borrower who arrives to an occupied spot (or a lender whose
spot wasn't vacated) can report it on an active booking. New `booking_reports` table +
edge function `report-booking-issue` that flags the booking, notifies the building
admin, and feeds a -5 into the apartment_scores view. Admin screen lists open reports
with resolve/dismiss actions, audited via the existing admin audit trail (migration 009).
```

### 3.2 Calendar view of my spot & bookings

**Prompt:**
```
Add a month calendar view to ParkingTrade using table_calendar. Show, per day: my
spot's availability periods (from spot_availability_periods), bookings where I'm lender
(one color) and borrower (another), and recurring-swap days. Tapping a day opens a
bottom sheet with that day's entries and quick actions (cancel, open chat, edit
availability). Reuse BookingService and ParkingSpotService; no backend changes.
```

### 3.3 Guest parking requests

**Prompt:**
```
Add guest parking: a resident can request a spot for a visitor, entering the guest's
car plate. Extend booking_requests with nullable guest_name and guest_plate columns
(migration), pass them through create-booking-request and approve-booking, and show a
"Guest" chip on booking cards. The lender sees the plate so they can verify the car.
```

### 3.4 Weekly building digest (admin)

**Prompt:**
```
Add a weekly digest edge function `building-digest` scheduled via pg_cron: per
building, compute bookings created/completed, top 3 leaderboard movers, and open
reports, then push a summary notification to building admins (role from migration 006).
Include an opt-out flag on profiles.
```

### 3.5 Smart availability suggestions

**Prompt:**
```
Analyze an apartment's booking history to suggest availability periods: if a spot is
never used weekdays 09:00–17:00 but has no availability period covering it, prompt the
owner ("Your spot sat empty 12 weekdays this month — open it up?"). Implement as an RPC
computing gaps from booking_requests vs spot_availability_periods, surfaced as a
dismissible card on the spot screen.
```

### 3.6 Waze / Google Maps deep link on active booking

**Prompt:**
```
On an active booking card, add "Navigate" that deep-links to Waze (fallback Google
Maps) using the building lat/lng from migration 016 via url_launcher. Append the spot
number to the notification/screen so the borrower knows where to park.
```

---

## Suggested build order

| # | Feature | Depends on | Size |
|---|---------|-----------|------|
| 1 | Waitlist/queue (1.1) ✅ | — | M |
| 2 | Chat on match (1.2) ✅ | — | S |
| 3 | Queue push notifications (1.3) ✅ | 1.1 | S |
| 4 | Scoreboard (2.1) | — | M |
| 5 | Recurring swaps (2.2) | — | L |
| 6 | No-show reporting (3.1) | 2.1 (scoring) | S |
| 7 | Calendar view (3.2) | — | M |
| 8 | Guest parking (3.3) | — | S |
| 9 | Weekly digest (3.4) | 2.1, 3.1 | S |
| 10 | Smart suggestions (3.5) | — | M |
| 11 | Navigation deep link (3.6) | — | XS |

**Tips for using the prompts:** run one feature per session/branch; after each, run `flutter analyze --no-fatal-infos`, `flutter test`, and the e2e suite; deploy with `supabase db push` + `supabase functions deploy` per the checklist in CLAUDE.md.
