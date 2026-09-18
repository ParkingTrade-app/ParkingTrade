## Parking Trade – Project Specification

### 1. Product Overview

- **Problem**: Residents in high‑rise buildings struggle to efficiently share or rent parking spots inside their building.
- **Solution**: A **building‑gated parking swap app** where residents:
  - Join their building via invite codes.
  - Register and manage parking spots.
  - Create and approve booking requests.
  - Chat in real‑time per booking.
- **Privacy**: Phone numbers stay in Supabase Auth metadata; app‑visible identity is via profile IDs, display names, and building membership.

### 2. Tech Stack & Architecture

- **Frontend**
  - Flutter (Dart 3.x), Material 3, Provider for state.
  - Platforms: iOS, Android, and Web (Flutter Web). Web uses entry point `lib/main_web.dart`; run/build with `-t lib/main_web.dart` and Supabase `--dart-define` flags. See **§14 Web support** for details and optional web push.
  - Structure (under `lib/`):
    - `config/` – runtime config (e.g. `supabase_config.dart`, `app_router.dart`).
    - `models/` – plain data models with `fromJson` / `toJson`.
    - `providers/` – Riverpod notifiers.
    - `services/` – business logic, Supabase and Edge Function access.
    - `screens/` – feature‑grouped UI: `auth/`, `building/`, `spots/`, `bookings/`, `chat/`.
    - `widgets/` – reusable UI components.
- **Backend**
  - Supabase:
    - PostgreSQL database with RLS and policies.
    - Supabase Auth (phone‑based OTP).
    - Realtime for chat and live updates.
  - Supabase Edge Functions (Deno + TypeScript) for transactional flows:
    - `join-building` (stub / legacy; magic-login flow replaced invite join)
    - `create-building` (**deprecated** — pre–apartment-centric; do not use from the app)
    - `create-building-admin` (**active** — creates `buildings` + `ADMIN-UNIT` apartment + admin `profiles`; sets `created_by_user_id`; omits `display_name` in upsert when `admin_display_name` is not sent so Google-provided names are preserved)
    - `create-booking-request`
    - `approve-booking`
  - Push notifications via Firebase:
    - FCM (Android) / APNs (iOS) through Firebase Cloud Messaging; same project can send to **web** tokens (browser push) when Firebase web app and Edge secrets are configured.
    - Tokens stored in `user_fcm_tokens` (migration `005_user_fcm_tokens.sql`); Edge Functions use shared `_shared/fcm.ts` to send push from `create-booking-request` (to lender) and `approve-booking` (to borrower).
- **Repo Layout**
  - `lib/` – Flutter client.
  - `supabase/migrations/` – SQL migrations (numbered, source of truth).
  - `supabase/functions/` – Edge Functions (one folder per function).

### 3. Core Domains & Business Rules

- **Buildings**
  - Identified by invite codes (e.g. `TEST123`). Optional `address` (full formatted address from Places API) and `created_by_user_id` (user who created the building, for future owner/admin flows).
  - Creation: buildings for **new building admins** are created via the `create-building-admin` Edge Function (no client INSERT on `buildings`). It generates a unique 6-character invite code, sets `created_by_user_id` to the caller, creates the `ADMIN-UNIT` apartment, and upserts the caller’s `profiles` row with `role = admin`, `apartment_id`, and `status = approved`. The legacy `create-building` function remains in the repo for compatibility only.
  - Flags:
    - `approval_required`:
      - `false`: users join and are immediately active.
      - `true`: users join as `pending` until approved by an admin/owner.
  - Building membership gates all interactions: profiles, spots, bookings, messages.

- **Profiles**
  - Represent app‑level users (linked to Supabase Auth user).
  - Key attributes: `id`, `building_id`, `status` (`pending`, `approved`, etc.), `display_name`.
  - Phone numbers never stored here, only in `auth.users.metadata`.
  - RLS:
    - User can always read their own profile.
    - User can read profiles in their building via a helper function (to avoid RLS recursion).

- **Parking Spots**
  - Owned by a single resident and scoped to a building.
  - Business rules:
    - Unique per building + identifier (e.g. `UNIQUE (building_id, spot_identifier)`).
    - `is_active` determines whether spot is bookable or surfaced in booking flows.

- **Spot Availability Periods**
  - Table: `spot_availability_periods`.
  - Owners can define multiple availability windows (date‑time ranges) per spot.
  - **Recurring templates** (`is_recurring`, `recurring_pattern` TEXT): weekly JSON `{"type":"weekly","days":["MON","WED"],"until":"ISO?"}` or legacy keywords `daily` / `weekly` / `weekdays` / `weekends`. The Flutter client still inserts the JSON as a string — the column stays TEXT so that payload does not become a JSONB scalar. SQL `parse_recurring_pattern(text)` + `expand_availability_occurrences(spot_id, from, to)` (migration 046) are the server source of truth (UTC day-walk, 90-day clamp). Dart `expandRecurringPeriods` remains for search / create. Occurrences are **not** materialized as rows. The availability management UI hides recurring templates whose `until` is in the past (same as expired one-shots) and shows the next 1–4 occurrences as a subtitle via the SQL RPC, falling back to the Dart expander if the RPC fails.
  - Booking search / create:
    - If spot has availability periods: requests must **overlap** at least one expanded occurrence (`spot_availability_overlaps`, enforced in `create-booking-request`).
    - If no periods defined: spot is considered always available (backward‑compatible).
  - Waitlist: publishing a one-shot window matches overlapping `waiting` entries (032). Publishing a recurring template expands the next 30 days and matches each occurrence. Waiters who join *after* a template was published are matched by `match_waitlist_against_upcoming_availability()` (pg_cron `match-waitlist-upcoming` in `bootstrap.sql`). Matching stays informational — booking still races through the overlap constraint.
  - RLS:
    - Owners can manage their spot’s availability periods.
    - Other building members can read periods for spots they can book.

- **Booking Requests / Bookings**
  - Table: `booking_requests` (or equivalent bookings table).
  - Represents a request by a borrower to use a spot from a lender.
  - Key attributes:
    - `spot_id`, `borrower_id`, `lender_id`.
    - `start_time`, `end_time`.
    - `status` enum (e.g. `pending`, `approved`, `rejected`, `cancelled`).
  - Core rules:
    - **Building‑gated**: borrower, lender, and spot must be in same building.
    - **No self‑booking**: borrower cannot request their own spot.
    - **Time validity**: `end_time > start_time`.
    - **Double‑booking prevention**:
      - Enforced via PostgreSQL exclusion constraints and GiST indexes on time ranges (e.g. `tstzrange(start_time, end_time)`).
      - Second approval for an overlapping time range on the same spot must fail with a clear error.
  - **Completion**: `complete_expired_bookings()` (pg_cron every 15 min) flips `approved → completed` once `end_time + 2 hours` has passed. The 2-hour grace exists so a lender can still file `borrower_overstay` before the row leaves `approved`.
  - **Booking issues / no-show (migration 047)**: explicit reports, not inferred. Table `booking_issues` (`lender_did_not_vacate` | `borrower_did_not_arrive` | `borrower_overstay`; status `open` | `upheld` | `dismissed`). `report_booking_issue(booking_id, kind, notes)` is SECURITY DEFINER — caller must be an approved member of the borrower apartment (`lender_did_not_vacate`) or lender apartment (the other two kinds); window is `start_time` through `end_time + 24 hours` on `approved`/`completed` rows; one open report per apartment per booking. `resolve_booking_issue(issue_id, upheld|dismissed, notes)` is building-admin-only and does **not** rewrite the booking. Writes `admin_audit_log.booking_issue_id`. Push via `booking_issue_notifications` outbox drained by `notify-booking-issue` (pg_cron + opt-in Vault webhook, migration 048, secrets `issue_notify_*`). `apartment_scores` (Roadmap 2.1, migration 050) counts `status = 'upheld'` against the accused apartment.
  - **Building scoreboard (migration 050, Roadmap 2.1 backend)**: view `apartment_scores` (owner-run, SELECT revoked from `anon`/`authenticated`) plus SECURITY DEFINER RPC `get_building_leaderboard(p_building_id)` — approved members may query **only their own building**. Weights live in `leaderboard_score_weights()`: completed lend +10, hour lent +1, reciprocal completed swap +15 each side, upheld issue −5 (`lender_did_not_vacate` → lender; `borrower_did_not_arrive` / `borrower_overstay` → borrower). Open/dismissed issues do not score. No Flutter UI in this slice. E2E: `e2e/src/scenarios/20-building-scoreboard.ts`.
  - **Admin booking SELECT (migration 049)**: building admins (`role=admin`, `status=approved`) may `SELECT booking_requests` in their building via `get_user_building_id()`, matching the 036 UPDATE shape. Party-only SELECT from 013 is unchanged; non-party residents and foreign admins still see nothing. This unblocks the admin issues list join (`booking_requests` + `parking_spots`) and booking-detail resolve for a non-party admin.
  - **Flutter API layer**: `lib/models/booking_issue.dart` (`BookingIssue`, `kindsFor`, `isReportWindowOpen`) and `lib/services/booking_issue_service.dart` wrap the two RPCs plus `listForBooking` / `listForBuilding` / `countOpen`.
  - **Resident reporting (booking detail)**: `BookingDetailScreen` loads issues via `listForBooking`. A **Report issue** outlined button is shown when the caller is a booking party, the report window is open (`approved`/`completed`, `now ∈ [start, end+24h]`), and the current apartment has no `open` issue. `lib/screens/bookings/report_booking_issue_sheet.dart` collects a party-gated kind (`kindsFor`) plus optional notes (≤500) and calls `report_booking_issue`. Existing issues render as cards (kind, status chip, notes); resolved cards stay visible and read-only. Building admins also see **Uphold** / **Dismiss** on `open` cards, using the same resolve dialog as the admin list.
  - **Admin open-issues screen**: `AdminBookingIssuesScreen` at GoRoute `/admin-issues` (`_requireAdmin`; also registered on web). Filter chips Open (default) / Upheld / Dismissed / All, pull-to-refresh, empty state. Cards show localized kind, spot id, booking window, reporter apartment, notes, `created_at`, status chip. Open rows: Uphold / Dismiss → `resolve_booking_issue_dialog.dart` (optional notes ≤500). Tap row → `BookingDetailScreen`. Dashboard AppBar `IconButton` + `Badge` (`countOpen`) pushes `/admin-issues`; `TabController` stays length 8. FCM `type=booking_issue` + `event=reported` + `profile.isAdmin` → `/admin-issues`; everyone else (and `resolved`) → booking detail.

- **Messages / Chat**
  - Table: `messages`, with `booking_id`, `sender_id`, `content`, timestamps.
  - Chat is strictly scoped per booking:
    - Only participants in the booking can read/write messages for that booking.
  - Privacy:
    - No phone numbers or PII in message payloads.
    - Clients use IDs, display names, and avatars only.
  - Realtime:
    - Supabase Realtime subscriptions per `booking_id`.

### 4. User Flows (Happy Paths)

- **Authentication & Onboarding**
  - Sign-in options (single auth screen):
    - **Sign in with Google**: User taps "Continue with Google"; OAuth redirects to Google then back to the app; Supabase restores the session. On web, redirect URL must match the app origin (see §5.2 Google OAuth setup).
    - **Sign in with Phone (OTP)**: User enters phone number (E.164 format, e.g. `+1234567890`). App requests OTP via Supabase Auth (phone provider). User enters OTP and is authenticated.
  - After either method, the user has a session. An `AuthWrapper` listens to auth changes and:
    - If no profile/building: routes to **Join or create building**.
    - If profile status is `pending`: routes to `Pending Approval`.
    - If `approved`: routes to `Home`.

- **Join or create building**
  - Single "Your building" screen with two paths:
    - **Join existing**: (A) "I have an invite code" – enter code and optional display name, then Join. (B) "Find my building" – search by name, tap a building to join (uses that building’s invite code). If building has `approval_required`, user is routed to pending until approved.
    - **Create new (admin onboarding)**: From **Not registered** → "Create building" link opens `/setup` (`CreateBuildingScreen`). Enter building name and address (Places autocomplete when configured). Submit invokes `create-building-admin` with optional `admin_display_name` from Google user metadata; on success the app navigates to **Admin dashboard**. `BuildingService.createBuilding()` is removed (throws `UnimplementedError`); do not call the legacy `create-building` function from new code.
    - **Create additional building (existing admin)**: An already-authenticated admin can create a new building from **Admin Dashboard → Building Settings tab → "Create New Building"** button. After a confirmation dialog, they are navigated to `/setup` (`CreateBuildingScreen`). On success the `create-building-admin` edge function upserts the admin's `profiles` row to point to the new building's `ADMIN-UNIT` apartment, effectively switching their active building. The app then navigates to the **Admin Dashboard** (stack replaced), which reloads with the new building's data.
  - After join or create: if `approval_required` and status `pending`, user is routed to Pending Approval; otherwise to parking spots (Home).

- **Manage Parking Spots**
  - From spots screen:
    - Add spot: provide human‑readable `spot_identifier` (e.g. `A‑101`).
    - Toggle `is_active` to temporarily disable a spot from bookings.
  - Constraints:
    - Duplicate identifiers for the same building should fail with a meaningful error.

- **Spot Availability Management**
  - Owner opens a spot and navigates to its availability UI (calendar icon).
  - Can:
    - Add availability periods by selecting start and end times.
    - View and delete existing periods.

- **Booking Flow (2‑user scenario)**
  - User A:
    - Joins building.
    - Adds active parking spot (optionally with availability periods).
  - User B:
    - Joins same building.
    - Opens `Request Spot` tab.
    - Chooses date/time range for a booking.
    - Sees only spots that:
      - Are active.
      - Are in the same building.
      - Have availability that overlaps the requested time (or no periods defined).
    - Submits booking request.
  - User A:
    - Opens `Bookings` → `Pending`.
    - Reviews request, then **Approve** or **Reject**.
    - On approve:
      - DB constraint verifies no time overlap with existing approved bookings for that spot.
  - User B:
    - Sees approved booking in `Active` tab and can open chat.

- **Chat Flow**
  - From booking detail, user opens chat.
  - Messages are sent and received in real‑time between borrower and lender only.
  - Historical messages load when chat is reopened, ordered by timestamp.

### 5. Setup & Environment

#### 5.1 Local Environment (Flutter)

- **Install Flutter**
  - On macOS (recommended):
    - Via Homebrew:
      - `brew install --cask flutter`
      - `flutter doctor`
    - Or manual clone:
      - `git clone https://github.com/flutter/flutter.git -b stable`
      - Add `flutter/bin` to `PATH` and run `flutter doctor`.
  - Install platform tooling:
    - iOS: install Xcode + command‑line tools.
    - Android: install Android Studio, SDK, accept Android licenses.

- **Project Dependencies**
  - From project root:
    - `flutter pub get`
  - This pulls Flutter packages such as `supabase_flutter`, `provider`, `firebase_core`, `firebase_messaging`, `flutter_local_notifications`, `intl`, `uuid`, `http`, etc.

#### 5.2 Supabase

- **Create Project**
  - Sign up at Supabase, create a new project, choose region and database password.

- **Run Migrations (Baseline Schema)**
  - In Supabase Dashboard → SQL Editor:
    - Run `supabase/migrations/001_initial_schema.sql` in full.
    - Run `supabase/migrations/002_overlap_constraint.sql` in full.
  - If you see **PGRST205** ("Could not find the table 'public.buildings'"), the database schema is missing: run the migrations above, then `003_fix_rls_recursion.sql`, `004_spot_availability_periods.sql`, `005_user_fcm_tokens.sql`, and `006_buildings_address_created_by.sql` in that order.
  - Alternative via CLI:
    - `npm install -g supabase`
    - `supabase login`
    - `supabase link --project-ref <project-ref>`
    - `supabase db push`

- **Additional Migrations**
  - RLS recursion fix:
    - Apply `003_fix_rls_recursion.sql` to avoid `infinite recursion detected in policy for relation "profiles"`.
    - Uses a `get_user_building_id()` helper function and revised policies.
  - Spot availability feature:
    - Apply `004_spot_availability_periods.sql` to create `spot_availability_periods` and related policies.
  - FCM token storage (for push to mobile and web):
    - Apply `005_user_fcm_tokens.sql` to create `user_fcm_tokens` (user_id, token, platform: ios | android | web) and RLS.
  - Buildings address and creator (for create-building flow):
    - Apply `006_buildings_address_created_by.sql` to add optional `address` and `created_by_user_id` to `buildings`.

- **Create Test Building**
  - For local/testing flows:
    ```sql
    INSERT INTO buildings (name, invite_code, approval_required)
    VALUES ('Test Building', 'TEST123', false);
    ```
  - This building is used by many guides and tests as the canonical example.

- **Google OAuth setup (optional, for "Continue with Google")**
  - In **Supabase Dashboard**: Authentication → Providers → enable **Google**. Add **Client ID** and **Client Secret** from Google Cloud Console. Under URL Configuration: set **Site URL** to the app origin (e.g. `https://yourdomain.com` or `http://localhost:PORT` for web dev). Add **Redirect URLs** to the allow list (e.g. `https://yourdomain.com/`, `http://localhost:PORT/`). Note the Supabase callback URL shown (e.g. `https://<project-ref>.supabase.co/auth/v1/callback`).
  - In **Google Cloud Console**: Create OAuth 2.0 credentials (Web application for web; optionally Android/iOS for native). Under **Authorized JavaScript origins** add the app origin(s). Under **Authorized redirect URIs** add the Supabase callback URL from the dashboard.
  - The Flutter app uses `signInWithOAuth(OAuthProvider.google, redirectTo: ...)`; on web it passes the current origin so Supabase redirects back to the app after consent.

#### 5.3 Edge Functions

- **When to Use**
  - Recommended for production for:
    - `join-building` (legacy stub)
    - `create-building` (deprecated)
    - `create-building-admin` (building admin onboarding)
    - `create-booking-request`
    - `approve-booking`
  - For simple local testing, the app can temporarily talk directly to tables without functions, but long‑term flows should go through Edge Functions.

- **Deployment Workflow**
  - Install CLI: `npm install -g supabase`.
  - Login: `supabase login`.
  - Link project: `supabase link --project-ref <project-ref>`.
  - Deploy:
    - `supabase functions deploy join-building`
    - `supabase functions deploy create-building`
    - `supabase functions deploy create-building-admin`
    - `supabase functions deploy approve-booking`
    - `supabase functions deploy create-booking-request`
    - `supabase functions deploy places-autocomplete` (for address autocomplete on web; set secret `PLACES_API_KEY`)
  - **Push (FCM)**: To send push from Edge Functions, set Supabase secrets from Firebase service account JSON: `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, `FIREBASE_PRIVATE_KEY`. Then redeploy `create-booking-request` and `approve-booking`.

#### 5.4 Flutter App Configuration

- **Supabase Credentials**
  - At runtime, app needs:
    - `SUPABASE_URL` (e.g. `https://xxxxx.supabase.co`).
    - `SUPABASE_PUBLISHABLE_KEY` (publishable key from Supabase Dashboard → Project Settings → API; formerly called "anon public key").
    - `SUPABASE_ANON_KEY` is still supported for backward compatibility (maps to publishable key).
  - Options:
    - Pass as Dart defines:
      - `flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...`
      - Or use legacy: `--dart-define=SUPABASE_ANON_KEY=...` (still works)
    - Or set in `.env` file (see §14 Web support) or `lib/config/supabase_config.dart` for development builds.

- **Places API (address autocomplete when creating a building)**
  - **Web:** The app calls the `places-autocomplete` Edge Function (no CORS; API key stays server-side). Set the Google API key as a Supabase secret: `supabase secrets set PLACES_API_KEY=your-google-key`, then deploy the function: `supabase functions deploy places-autocomplete`.
  - **Mobile:** Set `PLACES_API_KEY` in `.env` or `--dart-define`; the app calls Google directly. See [.env.example](.env.example).
  - In Google Cloud Console: enable **Places API** (Place Autocomplete). Create an API key. Without the key/function, `/setup` building creation still works with plain text name/address.
  - **Troubleshooting:** (1) Web: deploy `places-autocomplete` and set the secret. (2) Type at least 3 characters for suggestions. (3) Mobile: add PLACES_API_KEY to `.env` and run with a script that passes it.

- **Firebase / Push Notifications**
  - Optional for basic testing; required for push features.
  - Setup:
    - Create Firebase project.
    - For Android: add app in Firebase console, download `google-services.json` to `android/app/`.
    - For iOS: add app, download `GoogleService-Info.plist` to `ios/Runner/`.
    - Enable Cloud Messaging.
  - For **web push**: add a Web app in the same Firebase project; pass web config via `--dart-define` (see §14) and configure `web/firebase-messaging-sw.js` with the same config for background push.

- **Sentry / Error Tracking (Observability)**
  - Optional; disabled by default (no-op) until a DSN is provided — same "empty string ⇒ disabled" pattern as `FirebaseOptionsWeb`.
  - **Flutter (mobile + web)**: `lib/config/sentry_config.dart` reads `SENTRY_DSN` and `APP_ENV` (`development` | `staging` | `production`) via `--dart-define`. `lib/main.dart` and `lib/main_web.dart` wrap their existing `main()` body in `SentryFlutter.init(...)` when `SentryConfig.isConfigured`; when not configured, the app runs exactly as it did before this integration (verified as a regression check). Errors only for now — `tracesSampleRate: 0.0`, no performance tracing or session replay yet.
    - On web, `main_web.dart`'s pre-existing `FlutterError.onError` / `PlatformDispatcher.instance.onError` handlers are chained *after* whatever `SentryFlutter.init` installs (captured via `previousOnError`/`previousPlatformOnError`), so both Sentry reporting and the existing debug logging run — don't overwrite Sentry's hooks when touching these handlers.
    - CI: `SENTRY_DSN` is a new optional secret — staging repo secret consumed by `deploy-web.yml` (`APP_ENV=staging`), and a **separate** `production`-environment secret consumed by `deploy-production.yml` (`APP_ENV=production`), matching the existing staging/production secret-separation pattern.
    - Mobile (Android/iOS) store builds are still manual (see Workstream C below) — pass `--dart-define=SENTRY_DSN=... --dart-define=APP_ENV=production` by hand when that pipeline exists.
  - **Edge Functions**: `supabase/functions/_shared/sentry.ts` — a dependency-free `captureException()` that POSTs directly to Sentry's ingestion API using only the DSN (no SDK import; this repo avoids esm.sh/deno.land x-imports for Deno code after prior flakiness — see `push.ts`/`create-booking-request` header comments). Always resolves, never throws — a Sentry outage can't break a function. Enabled via the `SENTRY_DSN` Supabase secret, synced by `scripts/bootstrap-env.sh` (optional — omitted ⇒ unset ⇒ no-op) in both `deploy-staging.yml` and `deploy-production.yml`.
    - **First-PR rollout**: wired into `create-booking-request` and `approve-booking` only (highest-traffic, already do outbound push). Wiring the remaining Edge Functions (`create-building-admin`, `manage-member`, `send-chat-message`, the `notify-*` drains, etc.) is a follow-up — add `import { captureException } from '../_shared/sentry.ts'` and call it from each function's top-level catch block.

- **Production Firebase project readiness (Workstream C · Release Engineering)**
  - Production uses its **own** Firebase project (separate from the staging project used by `main`), registered under the app id `com.parkingtrade.app` (unified across Android/iOS since PR #33).
  - No code changes are required to point mobile builds at a different Firebase project: `android/app/google-services.json` and `ios/Runner/GoogleService-Info.plist` are gitignored and read at build time; `lib/firebase_initializer.dart` calls plain `Firebase.initializeApp()` with no embedded project config. Swapping projects is a **file drop-in**, not a code change:
    - Drop the production `google-services.json` into `android/app/` and the production `GoogleService-Info.plist` into `ios/Runner/` only on the machine/CI job doing the production build — never commit them.
    - No `com.google.gms.google-services` Gradle plugin is applied (and none is needed): `firebase_core`'s Android implementation parses `google-services.json` directly, since this app doesn't use Crashlytics/Performance/Analytics.
  - **Web** Firebase config for production is already environment-isolated: `deploy-production.yml` reads `FIREBASE_WEB_API_KEY`/`FIREBASE_WEB_APP_ID`/`FIREBASE_WEB_PROJECT_ID`/`FIREBASE_WEB_MESSAGING_SENDER_ID`/`FIREBASE_WEB_AUTH_DOMAIN`/`FIREBASE_WEB_STORAGE_BUCKET` and `FIREBASE_PROJECT_ID`/`FIREBASE_SERVICE_ACCOUNT` from the `production` GitHub Environment (separate from the staging repo secrets of the same name) — just populate those secrets with the new production Firebase project's values, no workflow change needed.
  - **Server-side push** (Edge Functions `_shared/fcm.ts`) needs its own prod values for `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, `FIREBASE_PRIVATE_KEY` set as `production`-environment secrets, sourced from the new project's service-account JSON.
  - There is currently **no CI job that builds/signs mobile artifacts** (Android AAB or iOS IPA) — those remain manual per the Deployment Checklist in `CLAUDE.md` until a dedicated mobile release workflow is added (see iOS release strategy below).

- **iOS release strategy (Workstream C · Release Engineering)**
  - **Push Notifications capability**: `ios/Runner/Runner.entitlements` declares `aps-environment` (currently `development`; Xcode's automatic signing swaps this to the correct value based on the provisioning profile type at archive time for Distribution builds — verify this at first real archive). Wired into all three `Runner` target configs via `CODE_SIGN_ENTITLEMENTS`.
  - `Info.plist` declares `UIBackgroundModes` → `remote-notification` so FCM can wake the app in the background.
  - Code signing: `Runner` target build configs now explicitly set `CODE_SIGN_STYLE = Automatic` for Debug/Profile/Release. The project-level hardcoded `CODE_SIGN_IDENTITY[sdk=iphoneos*] = "iPhone Developer"` was removed from the **Release** config only (kept for Debug/Profile) so Xcode can select a Distribution identity automatically when archiving for App Store Connect, rather than forcing a Development identity.
  - No `DEVELOPMENT_TEAM` is committed — it must come from the signing environment (local Xcode account or CI secret), since it differs between a developer's personal team and any CI/organization team.
  - **Planned CI**: a dedicated `deploy-ios.yml` (manual `workflow_dispatch` initially, mirroring the `production` environment gate pattern) using **Fastlane `match`** for certificate/profile management plus an **App Store Connect API key** (`.p8` + Key ID + Issuer ID) for authentication — avoids manual `.p12`/profile renewal and matches the "no long-lived credentials in the repo" posture used elsewhere (Vault-scoped secrets, environment-gated prod secrets). Requires a `macos-latest` runner (the existing `_verify.yml`/`ci.yml` jobs are Ubuntu-only). Not yet implemented — pending Apple Developer Program account/team details.
  - `google-services.json`/`GoogleService-Info.plist` for iOS builds follow the same drop-in pattern as Android above; irrelevant until the iOS build workflow exists.

#### 5.5 DevOps / Deployment

- **First-time setup**
  - Install [Supabase CLI](https://supabase.com/docs/guides/cli).
  - Run `supabase login`.
  - From repo root run `supabase link --project-ref <ref>` (get ref from Supabase Dashboard → Project Settings → General).
  - For CI: add GitHub secrets `SUPABASE_ACCESS_TOKEN` and `SUPABASE_PROJECT_REF` (Settings → Secrets and variables → Actions). Optional: `SUPABASE_DB_PASSWORD` if `db push` prompts for it.
- **Local**
  - Run `./scripts/deploy-all.sh` to apply migrations and deploy Edge Functions (or run `./scripts/migrate.sh` then `./scripts/deploy-functions.sh`).
  - Scripts require Supabase CLI and a linked project; they change to repo root and source `.env` if present.
- **CI**
  - **GitHub Actions** [.github/workflows/ci.yml](.github/workflows/ci.yml) calls [_verify.yml](.github/workflows/_verify.yml) (never deploys). Job 1 — `supabase db reset` on a local stack to validate migrations. Job 2 — `flutter analyze --no-fatal-infos`, `flutter test --coverage --exclude-tags e2e`, **`flutter test test/integration/app_e2e_test.dart`** (host VM widget-level integration; no Android emulator — suite lives under `test/` so Flutter uses `AutomatedTestWidgetsFlutterBinding`; bounded `pump`/`waitFor` so repeating Skeleton/hero-glow controllers cannot hang `pumpAndSettle`; placeholder Supabase HTTP fails immediately while font CDNs stay allowed for Heebo), and `deno test supabase/functions/_shared/invite_code_test.ts` for invite-code generation shared by `create-building-admin` and legacy `create-building`. Job 3 — `scripts/check-bootstrap-consistency.sh`. Concurrency cancels overlapping runs. Deploy is separate: `deploy-staging.yml` / `deploy-production.yml` / manual `deploy-backend.yml`.
  - **Backend E2E** [.github/workflows/e2e.yml](.github/workflows/e2e.yml) — boots a local Supabase stack and runs the Node API suite in `e2e/` (Auth, RLS, Edge Functions). Distinct from the Flutter `integration_test/` suite.
  - **Flutter emulator E2E (optional)** [.github/workflows/flutter_e2e_tests.yml](.github/workflows/flutter_e2e_tests.yml) — nightly + `workflow_dispatch` on `ubuntu-latest` + KVM (`reactivecircus/android-emulator-runner`, API 34). `continue-on-error: true`; **not** a PR merge gate. Same `integration_test/app_e2e_test.dart` suite as Job 2. Nested-KVM AVD boot is the flake vector (Issue #28); promote to required only after a stretch of green nightly runs.
  - **GitLab (optional):** [.gitlab-ci.yml](.gitlab-ci.yml) mirrors the same steps; set CI/CD variables (masked) `SUPABASE_ACCESS_TOKEN` and `SUPABASE_PROJECT_REF`.

### 6. Dart & Flutter Conventions

- **Linting & Style**
  - Follow `analysis_options.yaml` (includes `flutter_lints`).
  - Prefer:
    - `const` constructors and collections.
    - `debugPrint` over `print`.
    - Single quotes for strings unless interpolation/escaping is clearer.
  - Imports ordering:
    - Flutter/Dart SDK → third‑party packages → local files.

- **Models (`lib/models/`)**
  - Plain value types with:
    - `fromJson(Map<String, dynamic>)` factory using DB snake_case keys.
    - `toJson()` returning snake_case keys (matching API / DB).
  - Enums:
    - Provide explicit mapping to/from DB enum strings (`fromString`/`toString`).

- **Services (`lib/services/`)**
  - Each service manages its own `SupabaseClient`:
    - `final SupabaseClient _supabase = Supabase.instance.client;`
  - Encapsulate business logic and data access:
    - Screens call services.
    - Services may call Supabase tables or Edge Functions.
  - Throw well‑formed exceptions with user‑safe messages; screens decide how to surface them.

- **Screens (`lib/screens/`)**
  - Contain UI, navigation, and orchestrating async calls, but not core business rules.
  - Handle:
    - Form validation.
    - Loading states (`_isLoading` flags that reset on both success and failure).
    - Error messages (e.g. snackbars, dialogs, error labels).
  - Navigation:
    - Mobile entry point `lib/main.dart` uses **GoRouter** (`lib/config/app_router.dart`) with `context.go()` for top-level routes.

- **Notifications**
  - Centralize Firebase / FCM init in `main.dart` and `NotificationService`.
  - Background handlers must be top‑level functions with `@pragma('vm:entry-point')`.

### 7. Supabase Schema & RLS Conventions

- **General Schema Rules**
  - Migrations in `supabase/migrations/` are the single source of truth.
  - Naming:
    - Tables: plural snake_case (e.g. `booking_requests`, `parking_spots`).
    - Columns: descriptive snake_case (e.g. `created_at`, `building_id`).
    - Enums: snake_case values (e.g. `booking_status`, `profile_status`).
  - Always include timestamps:
    - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`.
    - `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` for mutable tables, with `update_updated_at_column()` trigger.

- **Constraints & Indexes**
  - Use constraints to enforce invariants:
    - `CHECK (end_time > start_time)` for time ranges.
    - Unique natural keys, e.g. `UNIQUE (building_id, spot_identifier)`.
  - Use indexes to support queries:
    - Foreign keys on `*_id`.
    - GiST index on time ranges for overlap checks.
    - Indexes on status columns for common filters.

- **RLS & Security**
  - RLS should mirror business rules:
    - Profiles and spots visible only to users in same building.
    - Booking requests only visible to borrower/lender and relevant building admins.
    - Messages scoped by `booking_id` and building membership.
  - Avoid recursive RLS:
    - Use helper functions (`SECURITY DEFINER`, `STABLE`) when policies need data from the same table.

### 8. Edge Functions Design Guidelines

- **Runtime & Imports**
  - Deno runtime:
    - Use versioned URL imports (`deno.land/std`, `esm.sh`).
    - Use `serve` from Deno std HTTP.
    - Use `createClient` from `@supabase/supabase-js@2`.

- **HTTP & CORS**
  - Always handle OPTIONS preflight:
    - If `req.method === 'OPTIONS'`, return early with `ok` + CORS headers.
  - Include a shared `corsHeaders` in all responses.
  - Return JSON bodies with `Content-Type: application/json`.

- **Auth & Security**
  - Use service‑role client where RLS must be bypassed:
    - Read `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` from env.
    - Configure client with `autoRefreshToken: false`, `persistSession: false`.
  - Authenticate callers:
    - Read `Authorization` bearer token.
    - `supabaseClient.auth.getUser(token)`; reject if missing/invalid.

- **Validation & Error Shape**
  - Parse and validate `req.json()`:
    - Check required fields and field types.
    - Validate domain rules (dates, building membership, self‑booking).
  - Error response shape:
    ```json
    { "error": "Human readable message", "details": "optional extra info" }
    ```
  - Status codes:
    - `400` invalid input.
    - `401` auth failures.
    - `403` building/authorization violations.
    - `404` not found.
    - `500` unexpected errors.

- **Domain‑Specific Rules**
  - Building membership:
    - Look up caller’s profile, ensure `status = 'approved'` and `building_id` set.
  - Booking:
    - Ensure borrower is in same building as spot + lender.
    - Prevent self‑booking.
    - Respect `is_active` and availability windows.
    - Cooperate with DB constraints to prevent double‑booking.

### 9. Testing & QA

- **Pre‑Testing Checklist**
  - Flutter deps installed (`flutter pub get`).
  - Supabase project created and migrations applied.
  - Test building (`TEST123`) created.
  - Supabase credentials wired into the app.
  - Phone auth enabled in Supabase (with or without SMS provider during dev).
  - Edge Functions deployed if testing production‑like flows.

- **Key Manual Scenarios**
  - Authentication:
    - **Google (web)**: "Continue with Google" → redirect to Google → sign in → redirect back to app → join building or home.
    - **Google (mobile)**: Same flow; ensure redirect URL in Supabase allow list matches app scheme/origin if using deep links.
    - **Phone OTP**: "Sign in with Phone" → enter phone → Send OTP → enter OTP → building join or home.
    - Invalid OTP: shows clear error.
    - Sign out: both providers use same sign-out; user can sign back in with either method.
  - Building join:
    - Valid code (`TEST123`): routes to spots.
    - Invalid code: shows “invalid invite code”.
    - Approval‑required building: lands on pending screen.
  - Spots:
    - Add spot.
    - Toggle active/inactive; inactive spots not offered in booking.
    - Duplicate identifier yields an error.
  - Booking:
    - Request spot from another user in same building.
    - Enforce valid time ranges.
    - Reject self‑booking and cross‑building requests.
  - Approval:
    - Lender approves/rejects, borrower sees expected status.
    - Double‑booking attempts are blocked by DB constraint.
  - Cancellation:
    - Borrower cancels an approved booking.
    - Lender cancels a pending request where allowed.
  - Chat:
    - Messages appear immediately for both parties.
    - History loads on reopen, ordered by time.
    - Chats are scoped per booking.
  - Privacy:
    - No phone numbers in profiles or messages, only in Auth metadata.

- **Database Verification (Example Queries)**
  - Validate expected rows in `buildings`, `profiles`, `parking_spots`, `booking_requests`, `messages`.
  - Check there are no overlapping approved bookings for same spot using range overlap queries.

### 10. SMS / Twilio Integration (Phone Auth)

- **Goals**
  - Use Supabase phone auth to send OTP codes via an SMS provider (Twilio recommended).
  - Support both quick development setups (logs/test numbers) and production setups.

- **Provider Options**
  - Twilio (primary / recommended for production).
  - MessageBird, Vonage as alternatives.
  - Supabase test mode / logs for OTP in dev only.

- **Twilio Setup (High‑Level)**
  - In Twilio:
    - Create account (trial or paid).
    - Get **Account SID**, **Auth Token**, and an SMS‑capable phone number.
    - For trial, verify all recipient numbers before use.
  - In Supabase:
    - Go to `Authentication → Providers → Phone`.
    - Enable Phone provider.
    - Enable Twilio and configure:
      - Account SID.
      - Auth Token.
      - Phone Number (E.164 with `+`).
      - Optionally Messaging Service SID (`MG...`) if used.
    - Save and verify the integration.

- **Development Without Full SMS Setup**
  - Enable Phone provider in Supabase, skip configuring Twilio initially.
  - For OTP codes:
    - Use Supabase logs (`Logs → Auth Logs`) to read OTPs.
    - Or use test phone numbers / test mode, when available.
  - This is dev‑only; production must have a real provider.

- **Common Twilio / Supabase Issues & Guidance**
  - Ensure app uses the same Supabase project where Twilio is configured.
  - Typical failure:
    - Status 422 `sms_send_failed` from `/auth/v1/otp`.
    - Twilio `20003 Authentication Error – invalid username`.
  - Checklist:
    - Project URL and project ref in app match the configured project.
    - Twilio credentials match exactly (no trailing/leading spaces).
    - Phone number format is E.164 with `+`.
    - For Twilio trial:
      - All destination numbers are verified in Twilio console.
  - Debugging:
    - Check Supabase Auth logs for full error messages and payloads.
    - Check Twilio SMS logs to confirm requests arrive and see exact errors.

### 11. Multi‑Tenant & Testing Patterns

- **Multiple Buildings**
  - You can seed multiple buildings with different invite codes.
  - Users in one building must not see spots/bookings of another.

- **Second Tenant Testing**
  - To test borrower/lender interactions:
    - Sign out and create a second account with a different phone number.
    - Join the same building (e.g. `TEST123`).
    - Use first account as spot owner; second as borrower.

### 12. Git & Deployment Notes

- **GitHub Remote**
  - Origin points to the GitHub repo for this project.
  - Standard workflow:
    - Commit changes locally with descriptive messages.
    - Push with `git push -u origin main` (using PAT/SSH/GitHub CLI).

- **Supabase / Edge Deployment**
  - Use Supabase CLI for migrations and functions deployment as described above.

### 13. iOS / Android Build Notes (Summary)

- **iOS (Firebase Messaging)**
  - Common issue: “Include of non‑modular header inside framework module 'firebase_messaging.FLTFirebaseMessagingPlugin'”.
  - Typical remediation:
    - `flutter clean && flutter pub get`.
    - In `ios/`: `pod deintegrate && pod install --repo-update`.
    - Ensure Podfile includes settings to allow non‑modular includes and uses Swift 5 where needed.
    - If issues persist, open `ios/Runner.xcworkspace` and build via Xcode once.

- **Android**
  - Standard Flutter Android builds with Firebase messaging typically require:
    - Valid `google-services.json`.
    - `flutter doctor` clean, Android SDK installed and licenses accepted.

### 14. Web Support (Flutter Web)

- **Overview**
  - The app runs on Flutter Web (iOS, Android, and browser). Core flows (auth, join building, spots, bookings, chat) work in the browser. **Web push** (browser notifications) is supported when Firebase web config is provided.

- **Prerequisites**
  - Enable web: `flutter config --enable-web`.
  - Verify device: `flutter devices` (expect `Chrome (web)`). If `web/` is missing: `flutter create . --platforms=web`.

- **Run locally**
  - Default placeholder credentials (same as `.env.example`) are built into `lib/config/supabase_config.dart`, so `./run_web.sh` or `./restart_web.sh` start the app without any config. For real Supabase (auth, DB): create a `.env` (gitignored) from `.env.example` and set `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` (or `SUPABASE_ANON_KEY` for backward compatibility), or pass them as env/args.
  - Or set env once: `export SUPABASE_URL='...'` and `export SUPABASE_PUBLISHABLE_KEY='...'` (or `SUPABASE_ANON_KEY='...'`), then `./run_web.sh` (port 8081 by default; set `WEB_PORT` to override).
  - Or pass as arguments: `./run_web.sh "https://YOUR_PROJECT.supabase.co" "your-publishable-key"`.
  - Restart: `./restart_web.sh` (same .env / env / args as `run_web.sh`).
  - Manual: `flutter run -d web-server -t lib/main_web.dart --web-port=8080 --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...` then open http://localhost:8080.
  - Chrome device: `flutter run -d chrome -t lib/main_web.dart --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...`
  - Get URL and publishable key from: Supabase Dashboard → Project Settings → API (look for "Publishable key", formerly called "anon public key").

- **Build for production**
  - `flutter build web -t lib/main_web.dart --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...` (or `--dart-define=SUPABASE_ANON_KEY=...` for backward compatibility)
  - Output: `build/web/`. Deploy to any static host (Vercel, Netlify, Firebase Hosting, Supabase Storage). Do not commit production keys; use CI/CD secrets for `--dart-define`.
  - **Base path**: Keep `web/index.html` with `<base href="$FLUTTER_BASE_HREF">`. Flutter replaces it at build time (default `/` for root). For a subpath (e.g. `example.com/app/`), add `--base-href=/app/` to the build command.

- **Web push (optional)**
  - Use the same Firebase project; add a **Web app** in Firebase Console and copy config (apiKey, appId, projectId, messagingSenderId).
  - Run/build with extra defines: `FIREBASE_WEB_API_KEY`, `FIREBASE_WEB_APP_ID`, `FIREBASE_WEB_PROJECT_ID`, `FIREBASE_WEB_MESSAGING_SENDER_ID`.
  - Edit `web/firebase-messaging-sw.js`: replace placeholder `firebaseConfig` with the same values (for background push when tab is closed).
  - Edge Functions need FCM secrets (`FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, `FIREBASE_PRIVATE_KEY`); migration `005_user_fcm_tokens.sql` must be applied; redeploy `create-booking-request` and `approve-booking`.
  - If Firebase web defines are omitted, the web app runs without requesting or storing push.

- **Web limitations**
  - Push: available only when Firebase web config and service worker are set up as above; otherwise users rely on in-app updates (realtime, booking lists).
  - Phone auth works as on mobile (Supabase OTP); ensure Supabase site URL / redirect URLs include your web origin if needed.

- **Web smoke-test**
  - Auth: phone → OTP → sign in. Join building (e.g. `TEST123`). Navigate Spots, Bookings, Chat without platform-specific crashes.

### 15. Project Documentation Rule

- **Spec-driven docs**: When implementing or changing features, update **specs.md** (this file) accordingly. Do **not** create separate `.md` files per feature or implementation; keep a single source of truth in `specs.md`.

