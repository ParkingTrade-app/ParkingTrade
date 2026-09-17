import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/announcements/announcements_screen.dart';
import '../screens/bookings/available_spots_screen.dart';
import '../screens/bookings/booking_detail_screen.dart';
import '../screens/chat/chat_screen.dart';
import 'auth_service.dart';

/// Global navigator key.
///
/// Used to navigate from contexts that don't have a [BuildContext] — for
/// example, notification tap handlers that fire outside the widget tree.
/// [MaterialApp.navigatorKey] is set to this in [main.dart].
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Handle a notification tap by inspecting the FCM [data] payload and
/// deep-linking to the appropriate screen.
///
/// Payload contract (set by the edge functions in `supabase/functions`):
/// - `type` — one of `booking_request`, `booking_approved`, `booking_rejected`,
///   `chat_message`, `waitlist_match`, `spot_available`, `building_announcement`,
///   `booking_issue`
/// - `booking_id` — the booking the notification refers to (all types except
///   `waitlist_match`, `spot_available` and `building_announcement`)
/// - `spot_id` + `start_time`/`end_time` — sent instead of `booking_id` for
///   `waitlist_match` (a spot + window a resident was waiting for) and
///   `spot_available` (a spot + window a neighbor just published — Roadmap 2)
/// - `announcement_id` + `building_id` — sent for `building_announcement`
///   (an admin broadcast — Roadmap Phase 4)
/// - `event` — `reported` | `resolved` on `booking_issue` payloads
Future<void> handleNotificationTap(Map<String, dynamic> data) async {
  final navigator = rootNavigatorKey.currentState;
  if (navigator == null) return;

  final type = data['type']?.toString();

  // Building announcements (Roadmap Phase 4) — open the history list.
  if (type == 'building_announcement') {
    navigator.push(
      MaterialPageRoute(builder: (_) => const AnnouncementsScreen()),
    );
    return;
  }

  // Waitlist matches (Roadmap 1.3) and new-availability broadcasts
  // (Roadmap 2) both refer to a spot + time window rather than a booking,
  // so they're handled before the booking_id guard below.
  if (type == 'waitlist_match' || type == 'spot_available') {
    final spotId = data['spot_id']?.toString();
    if (spotId == null || spotId.isEmpty) return;
    final start = DateTime.tryParse(data['start_time']?.toString() ?? '');
    navigator.push(
      MaterialPageRoute(
        builder: (_) => AvailableSpotsScreen(initialFilterStart: start),
      ),
    );
    return;
  }

  // New reports: building admins land on the issues inbox. Everyone else
  // (and `resolved` events) continues to booking detail below.
  if (type == 'booking_issue' && data['event']?.toString() == 'reported') {
    var profile = AuthService.cachedProfile;
    profile ??= await AuthService().getCurrentProfile();
    if (profile?.isAdmin == true) {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final router = GoRouter.maybeOf(ctx);
      if (router != null) {
        router.push('/admin-issues');
      } else {
        Navigator.of(ctx).pushNamed('/admin-issues');
      }
      return;
    }
  }

  final bookingId = data['booking_id']?.toString();
  if (bookingId == null || bookingId.isEmpty) return;

  switch (type) {
    case 'chat_message':
      navigator.push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(bookingId: bookingId),
        ),
      );
      return;
    case 'booking_request':
    case 'booking_approved':
    case 'booking_rejected':
    case 'booking_issue':
      navigator.push(
        MaterialPageRoute(
          builder: (_) => BookingDetailScreen(bookingId: bookingId),
        ),
      );
      return;
    default:
      // Unknown type — fall back to booking detail if we have an id.
      navigator.push(
        MaterialPageRoute(
          builder: (_) => BookingDetailScreen(bookingId: bookingId),
        ),
      );
  }
}
