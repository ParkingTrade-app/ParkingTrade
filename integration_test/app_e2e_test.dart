// integration_test/app_e2e_test.dart
//
// Device/emulator entry point for the widget-level suite that lives in
// test/integration/app_e2e_test.dart.
//
// Host CI (the PR gate) MUST run the test/ copy:
//   flutter test test/integration/app_e2e_test.dart
// Files under this directory force LiveTestWidgetsFlutterBinding, which
// hangs pumpAndSettle and trips pending-frame asserts on flutter-tester
// (Issue #28). This wrapper exists only for the optional nightly emulator
// job (.github/workflows/flutter_e2e_tests.yml).

import 'package:integration_test/integration_test.dart';

import '../test/integration/app_e2e_test.dart' as host;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  host.main();
}
