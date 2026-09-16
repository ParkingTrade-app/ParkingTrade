import 'package:flutter_test/flutter_test.dart';
import 'package:parking_trade/models/booking_issue.dart';
import 'package:parking_trade/models/booking_request.dart';

void main() {
  group('BookingIssue.fromJson', () {
    test('parses a flat RPC row', () {
      final issue = BookingIssue.fromJson({
        'id': 'iss-1',
        'booking_id': 'br-1',
        'building_id': 'bldg-1',
        'reporter_profile_id': 'prof-1',
        'reporter_apartment_id': 'apt-l',
        'kind': 'borrower_did_not_arrive',
        'status': 'open',
        'notes': 'Nobody showed',
        'resolved_by': null,
        'resolved_at': null,
        'resolution_notes': null,
        'created_at': '2026-09-16T10:00:00Z',
        'updated_at': '2026-09-16T10:00:00Z',
      });

      expect(issue.id, 'iss-1');
      expect(issue.bookingId, 'br-1');
      expect(issue.buildingId, 'bldg-1');
      expect(issue.reporterProfileId, 'prof-1');
      expect(issue.reporterApartmentId, 'apt-l');
      expect(issue.kind, BookingIssueKind.borrowerDidNotArrive);
      expect(issue.status, BookingIssueStatus.open);
      expect(issue.notes, 'Nobody showed');
      expect(issue.resolvedBy, isNull);
      expect(issue.resolvedAt, isNull);
      expect(issue.spotIdentifier, isNull);
      expect(issue.bookingStart, isNull);
      expect(issue.createdAt, DateTime.utc(2026, 9, 16, 10));
    });

    test('maps booking_requests + parking_spots embed', () {
      final issue = BookingIssue.fromJson({
        'id': 'iss-2',
        'booking_id': 'br-2',
        'building_id': 'bldg-1',
        'reporter_profile_id': 'prof-2',
        'reporter_apartment_id': 'apt-b',
        'kind': 'lender_did_not_vacate',
        'status': 'upheld',
        'notes': null,
        'resolved_by': 'admin-1',
        'resolved_at': '2026-09-16T12:00:00Z',
        'resolution_notes': 'Camera confirms',
        'created_at': '2026-09-16T11:00:00Z',
        'updated_at': '2026-09-16T12:00:00Z',
        'booking_requests': {
          'start_time': '2026-09-16T08:00:00Z',
          'end_time': '2026-09-16T10:00:00Z',
          'status': 'completed',
          'spot_id': 'sp-1',
          'borrower_apartment_id': 'apt-b',
          'lender_apartment_id': 'apt-l',
          'parking_spots': {'spot_identifier': '12A'},
        },
      });

      expect(issue.status, BookingIssueStatus.upheld);
      expect(issue.resolvedBy, 'admin-1');
      expect(issue.resolutionNotes, 'Camera confirms');
      expect(issue.bookingStart, DateTime.utc(2026, 9, 16, 8));
      expect(issue.bookingEnd, DateTime.utc(2026, 9, 16, 10));
      expect(issue.bookingStatus, BookingStatus.completed);
      expect(issue.bookingSpotId, 'sp-1');
      expect(issue.borrowerApartmentId, 'apt-b');
      expect(issue.lenderApartmentId, 'apt-l');
      expect(issue.spotIdentifier, '12A');
    });

    test('tolerates list-shaped embeds from PostgREST', () {
      final issue = BookingIssue.fromJson({
        'id': 'iss-3',
        'booking_id': 'br-3',
        'building_id': 'bldg-1',
        'reporter_apartment_id': 'apt-l',
        'kind': 'borrower_overstay',
        'status': 'dismissed',
        'created_at': '2026-09-16T11:00:00Z',
        'updated_at': '2026-09-16T12:00:00Z',
        'booking_requests': [
          {
            'start_time': '2026-09-16T08:00:00Z',
            'end_time': '2026-09-16T09:00:00Z',
            'status': 'approved',
            'spot_id': 'sp-9',
            'parking_spots': [
              {'spot_identifier': 'B2'},
            ],
          },
        ],
      });

      expect(issue.kind, BookingIssueKind.borrowerOverstay);
      expect(issue.bookingSpotId, 'sp-9');
      expect(issue.spotIdentifier, 'B2');
    });
  });

  group('BookingIssueKind', () {
    test('fromString round-trips every value', () {
      for (final kind in BookingIssueKind.values) {
        expect(BookingIssueKind.fromString(kind.toString()), kind);
      }
    });

    test('fromString throws on unknown', () {
      expect(() => BookingIssueKind.fromString('unknown'), throwsArgumentError);
    });
  });

  group('BookingIssueStatus', () {
    test('fromString round-trips every value', () {
      for (final status in BookingIssueStatus.values) {
        expect(BookingIssueStatus.fromString(status.toString()), status);
      }
    });

    test('fromString throws on unknown', () {
      expect(
        () => BookingIssueStatus.fromString('pending'),
        throwsArgumentError,
      );
    });
  });

  group('BookingIssue.kindsFor', () {
    test('borrower may only report lender_did_not_vacate', () {
      expect(
        BookingIssue.kindsFor(isLender: false),
        [BookingIssueKind.lenderDidNotVacate],
      );
    });

    test('lender may report did-not-arrive and overstay', () {
      expect(
        BookingIssue.kindsFor(isLender: true),
        [
          BookingIssueKind.borrowerDidNotArrive,
          BookingIssueKind.borrowerOverstay,
        ],
      );
    });
  });

  group('BookingIssue.isReportWindowOpen', () {
    final booking = BookingRequest(
      id: 'br-1',
      spotId: 'sp-1',
      borrowerApartmentId: 'apt-b',
      lenderApartmentId: 'apt-l',
      startTime: DateTime.utc(2026, 9, 16, 10),
      endTime: DateTime.utc(2026, 9, 16, 12),
      status: BookingStatus.approved,
      createdAt: DateTime.utc(2026, 9, 16),
      updatedAt: DateTime.utc(2026, 9, 16),
    );

    test('closed before start_time', () {
      expect(
        BookingIssue.isReportWindowOpen(
          booking,
          DateTime.utc(2026, 9, 16, 9, 59),
        ),
        isFalse,
      );
    });

    test('open at start_time', () {
      expect(
        BookingIssue.isReportWindowOpen(
          booking,
          DateTime.utc(2026, 9, 16, 10),
        ),
        isTrue,
      );
    });

    test('open during the booking', () {
      expect(
        BookingIssue.isReportWindowOpen(
          booking,
          DateTime.utc(2026, 9, 16, 11),
        ),
        isTrue,
      );
    });

    test('open at end_time + 24h inclusive', () {
      expect(
        BookingIssue.isReportWindowOpen(
          booking,
          DateTime.utc(2026, 9, 17, 12),
        ),
        isTrue,
      );
    });

    test('closed after end_time + 24h', () {
      expect(
        BookingIssue.isReportWindowOpen(
          booking,
          DateTime.utc(2026, 9, 17, 12, 0, 1),
        ),
        isFalse,
      );
    });

    test('open on a completed booking still inside the window', () {
      expect(
        BookingIssue.isReportWindowOpen(
          booking.copyWith(status: BookingStatus.completed),
          DateTime.utc(2026, 9, 16, 13),
        ),
        isTrue,
      );
    });

    test('closed for pending, cancelled, and rejected', () {
      for (final status in [
        BookingStatus.pending,
        BookingStatus.cancelled,
        BookingStatus.rejected,
      ]) {
        expect(
          BookingIssue.isReportWindowOpen(
            booking.copyWith(status: status),
            DateTime.utc(2026, 9, 16, 11),
          ),
          isFalse,
          reason: '$status must not be reportable',
        );
      }
    });
  });
}
