// integration_test/helpers/finders.dart
//
// Localisation-safe, structure-safe widget finders for ParkingTrade E2E tests.
//
// Why a dedicated finder layer?
// ─────────────────────────────
// The app is Hebrew-first (RTL) with EasyLocalization.  Hard-coding translated
// strings in test assertions is fragile — a copy-change breaks the test, not the
// feature.  This module provides:
//
//   • Semantic finders that locate widgets by *role* (e.g. the phone field,
//     the send-code button) rather than by raw text.
//   • Helper combiners that fall back gracefully when a widget has not yet
//     appeared in the tree (returns Finder, callers can use .evaluate().isEmpty
//     to branch).
//   • Known-stable Hebrew strings as named constants so all tests reference the
//     same source of truth.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Translation constants (Hebrew — app default locale)
//
// These are the *rendered* strings as they appear in he.json.
// Update here if the copy changes; all finders update automatically.
// ─────────────────────────────────────────────────────────────────────────────

/// Stable Hebrew strings used as finder anchors.
abstract class AppStrings {
  // Auth screen
  static const String sendCode = 'שלח קוד';
  static const String verifyAndContinue = 'אמת והמשך';
  static const String phonePlaceholder = '05X-XXX-XXXX';
  static const String phoneLabel = 'מספר טלפון';

  // Bottom nav tabs
  static const String navAvailableNow = 'פנויות עכשיו';
  static const String navMySpot = 'החניה שלי';

  // Hero toggle card (My Spot tab)
  static const String heroOccupied = 'תפוסה';
  static const String heroRelease = 'שחרר חניה';
  static const String heroMarkOccupied = 'סמן כתפוסה';
  static const String heroChangeTime = 'שנה שעה';
  static const String heroManage = 'נהל זמינות';
  static const String sharedWithNeighbors = 'משותף עם שכנים';
  static const String notSharing = 'לא משותף';
}

// ─────────────────────────────────────────────────────────────────────────────
// Auth screen finders
// ─────────────────────────────────────────────────────────────────────────────

class AuthFinders {
  AuthFinders._();

  /// The phone number input field.
  static Finder get phoneField =>
      find.byType(TextFormField).first;

  /// The "שלח קוד" (Send Code) primary button.
  static Finder get sendCodeButton =>
      find.widgetWithText(FilledButton, AppStrings.sendCode);

  /// The "אמת והמשך" (Verify & Continue) button shown after OTP is sent.
  static Finder get verifyButton =>
      find.widgetWithText(FilledButton, AppStrings.verifyAndContinue);

  /// The 6-digit OTP input field (appears after code is sent).
  /// We find it by its hint text '••••••' which is stable.
  static Finder get otpField =>
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            (w.decoration?.hintText == '••••••'),
      );

  /// The dev-bypass SMS button — useful to skip Twilio in CI.
  static Finder get devBypassButton =>
      find.widgetWithText(TextButton, '🛠️ Dev: Bypass SMS');
}

// ─────────────────────────────────────────────────────────────────────────────
// Home screen / ParkingSpotsScreen finders
// ─────────────────────────────────────────────────────────────────────────────

class HomeFinders {
  HomeFinders._();

  /// Bottom-nav "פנויות עכשיו" (Available Now) tab item.
  static Finder get availableNowTab =>
      find.text(AppStrings.navAvailableNow);

  /// Bottom-nav "החניה שלי" (My Spot) tab item.
  static Finder get mySpotTab =>
      find.text(AppStrings.navMySpot);

  /// The large "שחרר חניה" (Release spot) CTA inside the Hero Toggle Card.
  static Finder get releaseSpotButton =>
      find.widgetWithText(ElevatedButton, AppStrings.heroRelease);

  /// The "סמן כתפוסה" (Mark as occupied) outlined button.
  static Finder get markOccupiedButton =>
      find.widgetWithText(OutlinedButton, AppStrings.heroMarkOccupied);

  /// Status chip text when the spot is shared.
  static Finder get sharedChip =>
      find.textContaining(AppStrings.sharedWithNeighbors);

  /// Status chip text when the spot is not shared.
  static Finder get notSharingChip =>
      find.text(AppStrings.notSharing);

  /// Hero "תפוסה" (Occupied) large status text.
  static Finder get occupiedStatus =>
      find.text(AppStrings.heroOccupied);

  /// "שנה שעה" (Change time) chip in the unshared action panel.
  static Finder get changeTimeChip =>
      find.text(AppStrings.heroChangeTime);
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Waits up to [timeout] for [finder] to match at least one widget,
/// pumping the engine in [interval] steps.
///
/// Throws [TestFailure] if [finder] never matches within [timeout].
Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 8),
  Duration interval = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'waitFor: widget not found within $timeout.\n'
        'Finder description: ${finder.description}',
      );
    }
    await tester.pump(interval);
  }
}

/// Pumps until [finder] is gone (0 matches) or [timeout] elapses.
Future<void> waitForAbsence(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 8),
  Duration interval = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isNotEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'waitForAbsence: widget still present after $timeout.\n'
        'Finder description: ${finder.description}',
      );
    }
    await tester.pump(interval);
  }
}

/// Convenience: pump small fixed steps to advance animations without
/// requiring full settlement (useful when an animation loops indefinitely,
/// like the glow pulse on the hero card).
Future<void> pumpFrames(
  WidgetTester tester, {
  int frames = 10,
  Duration frameDuration = const Duration(milliseconds: 16),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(frameDuration);
  }
}
