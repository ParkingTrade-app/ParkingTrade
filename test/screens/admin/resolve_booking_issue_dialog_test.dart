import 'package:flutter_test/flutter_test.dart';
import 'package:parking_trade/screens/admin/resolve_booking_issue_dialog.dart';

void main() {
  group('resolveBookingIssueErrorKey', () {
    test('maps notes-length RPC message', () {
      expect(
        resolveBookingIssueErrorKey(
          Exception('resolution notes must be at most 500 characters'),
        ),
        'admin.issues.error_notes',
      );
    });

    test('maps admin-only RPC message', () {
      expect(
        resolveBookingIssueErrorKey(
          Exception('only building admins can resolve booking issues'),
        ),
        'admin.issues.error_admin',
      );
    });

    test('maps already-resolved RPC message', () {
      expect(
        resolveBookingIssueErrorKey(
          Exception('booking issue is already upheld'),
        ),
        'admin.issues.error_already',
      );
    });

    test('maps foreign-building RPC message', () {
      expect(
        resolveBookingIssueErrorKey(
          Exception('booking issue is not in your building'),
        ),
        'admin.issues.error_building',
      );
    });

    test('falls back to the generic key', () {
      expect(
        resolveBookingIssueErrorKey(Exception('connection reset')),
        'admin.issues.error_generic',
      );
    });
  });
}
