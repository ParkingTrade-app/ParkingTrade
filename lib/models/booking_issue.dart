import 'booking_request.dart';

/// A resident-filed trust report on a booking (no-show / occupied / overstay).
///
/// Backed by `booking_issues` (migration 047). Written only through
/// `report_booking_issue` / `resolve_booking_issue`. Optional embed fields
/// are populated when the query joins `booking_requests` (+ `parking_spots`).
class BookingIssue {
  final String id;
  final String bookingId;
  final String buildingId;
  final String? reporterProfileId;
  final String reporterApartmentId;
  final BookingIssueKind kind;
  final BookingIssueStatus status;
  final String? notes;
  final String? resolvedBy;
  final DateTime? resolvedAt;
  final String? resolutionNotes;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Present when fetched with a `booking_requests(...)` embed.
  final DateTime? bookingStart;
  final DateTime? bookingEnd;
  final BookingStatus? bookingStatus;
  final String? bookingSpotId;
  final String? borrowerApartmentId;
  final String? lenderApartmentId;

  /// Present when the embed includes `parking_spots(spot_identifier)`.
  final String? spotIdentifier;

  /// Present when the embed includes `apartments(identifier)` for the reporter.
  final String? reporterApartmentIdentifier;

  const BookingIssue({
    required this.id,
    required this.bookingId,
    required this.buildingId,
    this.reporterProfileId,
    required this.reporterApartmentId,
    required this.kind,
    required this.status,
    this.notes,
    this.resolvedBy,
    this.resolvedAt,
    this.resolutionNotes,
    required this.createdAt,
    required this.updatedAt,
    this.bookingStart,
    this.bookingEnd,
    this.bookingStatus,
    this.bookingSpotId,
    this.borrowerApartmentId,
    this.lenderApartmentId,
    this.spotIdentifier,
    this.reporterApartmentIdentifier,
  });

  factory BookingIssue.fromJson(Map<String, dynamic> json) {
    final booking = _embedMap(json['booking_requests']);
    final spot = booking == null ? null : _embedMap(booking['parking_spots']);
    final reporterApt = _embedMap(json['apartments']);

    return BookingIssue(
      id: json['id'] as String,
      bookingId: json['booking_id'] as String,
      buildingId: json['building_id'] as String,
      reporterProfileId: json['reporter_profile_id'] as String?,
      reporterApartmentId: json['reporter_apartment_id'] as String,
      kind: BookingIssueKind.fromString(json['kind'] as String),
      status: BookingIssueStatus.fromString(json['status'] as String),
      notes: json['notes'] as String?,
      resolvedBy: json['resolved_by'] as String?,
      resolvedAt: json['resolved_at'] != null
          ? DateTime.parse(json['resolved_at'] as String)
          : null,
      resolutionNotes: json['resolution_notes'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      bookingStart: booking?['start_time'] != null
          ? DateTime.parse(booking!['start_time'] as String)
          : null,
      bookingEnd: booking?['end_time'] != null
          ? DateTime.parse(booking!['end_time'] as String)
          : null,
      bookingStatus: booking?['status'] != null
          ? BookingStatus.fromString(booking!['status'] as String)
          : null,
      bookingSpotId: booking?['spot_id'] as String?,
      borrowerApartmentId: booking?['borrower_apartment_id'] as String?,
      lenderApartmentId: booking?['lender_apartment_id'] as String?,
      spotIdentifier: spot?['spot_identifier'] as String?,
      reporterApartmentIdentifier: reporterApt?['identifier'] as String?,
    );
  }

  /// Kinds the caller's apartment is allowed to file.
  ///
  /// Lender apartment: `borrower_did_not_arrive`, `borrower_overstay`.
  /// Borrower apartment: `lender_did_not_vacate`.
  static List<BookingIssueKind> kindsFor({required bool isLender}) {
    if (isLender) {
      return const [
        BookingIssueKind.borrowerDidNotArrive,
        BookingIssueKind.borrowerOverstay,
      ];
    }
    return const [BookingIssueKind.lenderDidNotVacate];
  }

  /// Client-side mirror of `report_booking_issue`'s window.
  ///
  /// Open when the booking is `approved` or `completed` and
  /// `now` is in `[start_time, end_time + 24 hours]` (inclusive).
  /// The RPC remains the authority.
  static bool isReportWindowOpen(BookingRequest booking, DateTime now) {
    if (booking.status != BookingStatus.approved &&
        booking.status != BookingStatus.completed) {
      return false;
    }
    final windowEnd = booking.endTime.add(const Duration(hours: 24));
    return !now.isBefore(booking.startTime) && !now.isAfter(windowEnd);
  }
}

/// PostgREST may return a many-to-one embed as an object or a single-element
/// list depending on the relationship hint.
Map<String, dynamic>? _embedMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is List && value.isNotEmpty && value.first is Map) {
    return Map<String, dynamic>.from(value.first as Map);
  }
  return null;
}

enum BookingIssueKind {
  lenderDidNotVacate,
  borrowerDidNotArrive,
  borrowerOverstay;

  static BookingIssueKind fromString(String value) {
    switch (value) {
      case 'lender_did_not_vacate':
        return BookingIssueKind.lenderDidNotVacate;
      case 'borrower_did_not_arrive':
        return BookingIssueKind.borrowerDidNotArrive;
      case 'borrower_overstay':
        return BookingIssueKind.borrowerOverstay;
      default:
        throw ArgumentError('Invalid booking issue kind: $value');
    }
  }

  @override
  String toString() {
    switch (this) {
      case BookingIssueKind.lenderDidNotVacate:
        return 'lender_did_not_vacate';
      case BookingIssueKind.borrowerDidNotArrive:
        return 'borrower_did_not_arrive';
      case BookingIssueKind.borrowerOverstay:
        return 'borrower_overstay';
    }
  }
}

enum BookingIssueStatus {
  open,
  upheld,
  dismissed;

  static BookingIssueStatus fromString(String value) {
    switch (value) {
      case 'open':
        return BookingIssueStatus.open;
      case 'upheld':
        return BookingIssueStatus.upheld;
      case 'dismissed':
        return BookingIssueStatus.dismissed;
      default:
        throw ArgumentError('Invalid booking issue status: $value');
    }
  }

  @override
  String toString() {
    switch (this) {
      case BookingIssueStatus.open:
        return 'open';
      case BookingIssueStatus.upheld:
        return 'upheld';
      case BookingIssueStatus.dismissed:
        return 'dismissed';
    }
  }
}
