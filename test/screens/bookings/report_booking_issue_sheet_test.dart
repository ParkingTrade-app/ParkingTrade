import 'package:flutter_test/flutter_test.dart';
import 'package:parking_trade/screens/bookings/report_booking_issue_sheet.dart';

void main() {
  group('reportBookingIssueErrorKey', () {
    test('maps the report-window RPC message', () {
      expect(
        reportBookingIssueErrorKey(
          Exception('report window is start_time through end_time + 24 hours'),
        ),
        'bookings.issues.error_window',
      );
    });

    test('maps unique-index / duplicate-key failures', () {
      expect(
        reportBookingIssueErrorKey(
          Exception(
            'duplicate key value violates unique constraint "uq_booking_issues_open_per_apartment"',
          ),
        ),
        'bookings.issues.error_already_open',
      );
      expect(
        reportBookingIssueErrorKey(Exception('23505 unique violation')),
        'bookings.issues.error_already_open',
      );
    });

    test('maps party-gated RPC messages', () {
      expect(
        reportBookingIssueErrorKey(
          Exception('only a booking party can report an issue'),
        ),
        'bookings.issues.error_party',
      );
      expect(
        reportBookingIssueErrorKey(
          Exception(
            'only the borrower apartment can report lender_did_not_vacate',
          ),
        ),
        'bookings.issues.error_party',
      );
      expect(
        reportBookingIssueErrorKey(
          Exception(
            'only the lender apartment can report borrower_did_not_arrive',
          ),
        ),
        'bookings.issues.error_party',
      );
    });

    test('maps notes-length and status RPC messages', () {
      expect(
        reportBookingIssueErrorKey(
          Exception('notes must be at most 500 characters'),
        ),
        'bookings.issues.error_notes',
      );
      expect(
        reportBookingIssueErrorKey(
          Exception('can only report on an approved or completed booking'),
        ),
        'bookings.issues.error_status',
      );
    });

    test('falls back to the generic key', () {
      expect(
        reportBookingIssueErrorKey(Exception('connection reset')),
        'bookings.issues.error_generic',
      );
    });
  });
}
