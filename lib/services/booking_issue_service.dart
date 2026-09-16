import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/booking_issue.dart';

/// Booking-trust reports (migration 047).
///
/// Writes go through SECURITY DEFINER RPCs (`report_booking_issue`,
/// `resolve_booking_issue`). Reads use RLS: booking parties and building
/// admins can SELECT; admins can also SELECT the underlying
/// `booking_requests` row (migration 049) so the admin list join works.
class BookingIssueService {
  final SupabaseClient _supabase = Supabase.instance.client;

  /// Admin-list embed: issue row + booking window/parties + spot identifier.
  static const adminListSelect =
      '*, booking_requests(start_time,end_time,status,spot_id,borrower_apartment_id,lender_apartment_id, parking_spots(spot_identifier))';

  /// File a report. [kind] is party-gated server-side; the window is
  /// `start_time` … `end_time + 24h` on `approved`/`completed` bookings.
  Future<BookingIssue> report({
    required String bookingId,
    required BookingIssueKind kind,
    String? notes,
  }) async {
    final trimmed = notes?.trim();
    try {
      final response = await _supabase.rpc(
        'report_booking_issue',
        params: {
          'p_booking_id': bookingId,
          'p_kind': kind.toString(),
          'p_notes': (trimmed == null || trimmed.isEmpty) ? null : trimmed,
        },
      );
      return BookingIssue.fromJson(_asMap(response));
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    }
  }

  /// Building-admin uphold or dismiss. Does not rewrite the booking.
  Future<BookingIssue> resolve({
    required String issueId,
    required BookingIssueStatus action,
    String? notes,
  }) async {
    if (action != BookingIssueStatus.upheld &&
        action != BookingIssueStatus.dismissed) {
      throw ArgumentError('action must be upheld or dismissed');
    }
    final trimmed = notes?.trim();
    try {
      final response = await _supabase.rpc(
        'resolve_booking_issue',
        params: {
          'p_issue_id': issueId,
          'p_action': action.toString(),
          'p_notes': (trimmed == null || trimmed.isEmpty) ? null : trimmed,
        },
      );
      return BookingIssue.fromJson(_asMap(response));
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    }
  }

  /// Issues on one booking, newest first. RLS: parties + building admins.
  Future<List<BookingIssue>> listForBooking(String bookingId) async {
    final response = await _supabase
        .from('booking_issues')
        .select()
        .eq('booking_id', bookingId)
        .order('created_at', ascending: false);

    return _mapList(response);
  }

  /// Open issues in the caller's building (admin dashboard default).
  Future<List<BookingIssue>> listOpenForBuilding() {
    return listForBuilding(status: BookingIssueStatus.open);
  }

  /// Building-scoped issues, newest first. RLS already limits the caller
  /// to their building (admin) or to bookings they are a party to.
  Future<List<BookingIssue>> listForBuilding({BookingIssueStatus? status}) async {
    final filter = _supabase.from('booking_issues').select(adminListSelect);
    final filtered =
        status != null ? filter.eq('status', status.toString()) : filter;
    return _mapList(await filtered.order('created_at', ascending: false));
  }

  /// Open issues visible to the caller — intended for the admin badge.
  Future<int> countOpen() async {
    final response = await _supabase
        .from('booking_issues')
        .select('id')
        .eq('status', BookingIssueStatus.open.toString());
    return (response as List).length;
  }

  List<BookingIssue> _mapList(dynamic response) {
    return (response as List)
        .cast<Map<String, dynamic>>()
        .map(BookingIssue.fromJson)
        .toList();
  }

  /// Scalar-composite RETURNS: PostgREST may wrap a single row in a list.
  Map<String, dynamic> _asMap(dynamic response) {
    if (response is List) {
      if (response.isEmpty) {
        throw Exception('Empty RPC response');
      }
      return Map<String, dynamic>.from(response.first as Map);
    }
    if (response is Map<String, dynamic>) return response;
    if (response is Map) return Map<String, dynamic>.from(response);
    throw Exception('Unexpected RPC response');
  }
}
