// integration_test/helpers/test_app_bootstrap.dart
//
// Central bootstrap for all integration / E2E tests.
//
// Usage in every test file:
//
//   void main() {
//     TestWidgetsFlutterBinding.ensureInitialized();
//     group('My flow', () {
//       testWidgets('...', (tester) async {
//         await TestAppBootstrap.pump(tester);
//         ...
//       });
//     });
//   }
//
// Design goals
// ─────────────
//   • MaterialApp wraps EasyLocalization (not the reverse) so repeated
//     testWidgets pumps still insert the child. saveLocale is false.
//   • Supabase is initialised once per process via a guard flag.  Calling
//     TestAppBootstrap.pump() from multiple tests is safe.
//   • Firebase is skipped in the test environment to avoid needing real
//     google-services.json / GoogleService-Info.plist at test time.
//   • Placeholder-credential runs install a fail-fast [HttpOverrides] so
//     initState network calls error immediately instead of hanging DNS/TLS
//     against placeholder.supabase.co (which leaves Skeleton shimmer
//     AnimationControllers repeating forever).
//   • pump() / pumpScreen() use bounded pumps. Home / hero helpers must
//     not pumpAndSettle against repeating animations.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parking_trade/config/supabase_config.dart';
import 'package:parking_trade/screens/auth/phone_auth_screen.dart';
import 'package:parking_trade/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Guards
// ─────────────────────────────────────────────────────────────────────────────

bool _supabaseInitialised = false;
bool _testEnvReady = false;

// ─────────────────────────────────────────────────────────────────────────────
// Bootstrap helper
// ─────────────────────────────────────────────────────────────────────────────

class TestAppBootstrap {
  TestAppBootstrap._();

  /// Pumps the full [ParkingTradeTestApp] into [tester] and settles the
  /// auth-route first frame (EasyLocalization + PhoneAuthScreen).
  ///
  /// [locale] defaults to Hebrew (he) — the app's production default.
  /// Pass `Locale('en')` to exercise the English locale branch.
  ///
  /// [pumpSettleTimeout] is the budget for EasyLocalization JSON load + first
  /// paint of PhoneAuthScreen (no repeating controllers on that route).
  static Future<void> pump(
    WidgetTester tester, {
    Locale locale = const Locale('he'),
    Duration pumpSettleTimeout = const Duration(seconds: 10),
  }) async {
    await pumpScreen(
      tester,
      home: const PhoneAuthScreen(),
      locale: locale,
      pumpSettleTimeout: pumpSettleTimeout,
    );
  }

  /// Pumps [home] under EasyLocalization → MaterialApp and waits for
  /// translation JSON. Must be the first EasyLocalization-as-parent pump in
  /// the process (later pumps never insert the child — host fake-async).
  static Future<void> pumpScreen(
    WidgetTester tester, {
    required Widget home,
    Locale locale = const Locale('he'),
    Duration pumpSettleTimeout = const Duration(seconds: 10),
  }) async {
    await _ensureTestEnvironment();
    await ensureSupabase();

    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('he'), Locale('en')],
        path: 'assets/translations',
        fallbackLocale: const Locale('he'),
        startLocale: locale,
        saveLocale: false,
        child: Builder(
          builder: (context) {
            final isRtl = context.locale.languageCode == 'he';
            return MaterialApp(
              theme: AppTheme.light(),
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              builder: (ctx, child) => Directionality(
                textDirection:
                    isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
                child: child!,
              ),
              home: home,
            );
          },
        ),
      ),
    );

    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      pumpSettleTimeout,
    );
  }

  static Future<void> _ensureTestEnvironment() async {
    if (_testEnvReady) return;
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    _testEnvReady = true;
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  /// Exposed internally so test helpers in the same package can call it
  /// (e.g. _pumpHeroCard in app_e2e_test.dart).
  static Future<void> ensureSupabase() async {
    await _ensureTestEnvironment();
    if (_supabaseInitialised) return;

    // In CI / unit-test environments the --dart-define values are often not
    // injected.  We fall back to dummy values so the SDK initialises without
    // throwing.
    final url = SupabaseConfig.supabaseUrl.isNotEmpty
        ? SupabaseConfig.supabaseUrl
        : 'https://placeholder.supabase.co';
    final key = SupabaseConfig.supabasePublishableKey.isNotEmpty
        ? SupabaseConfig.supabasePublishableKey
        : 'placeholder-anon-key';

    // Widget-level CI uses dummy creds. Reject placeholder/Supabase HTTP
    // immediately so home/feed initState cannot hang DNS and leave
    // Skeleton.repeat() running. Font CDNs stay allowed (AppTheme Heebo).
    final usingPlaceholder = url.contains('placeholder.supabase.co') ||
        key == 'placeholder-anon-key' ||
        SupabaseConfig.isPlaceholder;
    if (usingPlaceholder) {
      HttpOverrides.global = _FailFastHttpOverrides();
    }

    await Supabase.initialize(
      url: url,
      anonKey: key,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        autoRefreshToken: false,
      ),
    );
    _supabaseInitialised = true;
  }
}

/// Rejects placeholder/Supabase HTTP immediately; lets font CDNs through so
/// [AppTheme] can load Heebo without bundling the TTF in tests.
class _FailFastHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FailFastHttpClient(super.createHttpClient(context));
}

class _FailFastHttpClient extends Fake implements HttpClient {
  _FailFastHttpClient(this._inner);

  final HttpClient _inner;

  static bool _isAllowed(Uri url) {
    final host = url.host;
    return host == 'fonts.gstatic.com' ||
        host == 'fonts.googleapis.com' ||
        host.endsWith('.gstatic.com');
  }

  @override
  bool get autoUncompress => _inner.autoUncompress;

  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  Duration get idleTimeout => _inner.idleTimeout;

  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  String? get userAgent => _inner.userAgent;

  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  void close({bool force = false}) => _inner.close(force: force);

  Future<HttpClientRequest> _reject(Uri url) {
    return Future<HttpClientRequest>.error(
      SocketException('fail-fast: blocked ${url.host} in widget tests'),
      StackTrace.empty,
    );
  }

  Future<HttpClientRequest> _open(String method, Uri url) {
    if (_isAllowed(url)) return _inner.openUrl(method, url);
    return _reject(url);
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _open(method, url);

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) =>
      _open(method, Uri(scheme: 'https', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _open('GET', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _open('POST', url);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => _open('PUT', url);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _open('DELETE', url);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => _open('HEAD', url);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _open('PATCH', url);
}

