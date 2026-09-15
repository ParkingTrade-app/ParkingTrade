import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_router.dart';
import 'config/sentry_config.dart';
import 'config/supabase_config.dart';
import 'config/places_config.dart';
import 'firebase_initializer_stub.dart' if (dart.library.io) 'firebase_initializer.dart' as firebase_init;
import 'services/notification_service_stub.dart' if (dart.library.io) 'services/notification_service.dart';
import 'theme/app_theme.dart';

void main() async {
  if (SentryConfig.isConfigured) {
    await SentryFlutter.init(
      (options) {
        options.dsn = SentryConfig.dsn;
        options.environment = SentryConfig.environment;
        // Errors only for now — no performance tracing/session replay yet.
        options.tracesSampleRate = 0.0;
      },
      appRunner: _runApp,
    );
  } else {
    await _runApp();
  }
}

Future<void> _runApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  debugPrint('### MAIN STARTED ###');
  debugPrint('### TIME: ${DateTime.now().toIso8601String()} ###');

  if (!kIsWeb) {
    try {
      await firebase_init.initializeFirebase();
    } catch (e) {
      debugPrint('Warning: Firebase initialization failed: $e');
      debugPrint(
        'Push notifications may not work. Make sure GoogleService-Info.plist (iOS) and google-services.json (Android) are configured.',
      );
    }
  }

  if (!SupabaseConfig.isConfigured) {
    throw Exception(
      'Supabase configuration is missing. Please set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY (or SUPABASE_ANON_KEY for backward compatibility).',
    );
  }

  const supabaseUrl = SupabaseConfig.supabaseUrl;
  final supabasePublishableKey = SupabaseConfig.supabasePublishableKey;

  debugPrint('================ Supabase Runtime Config ================');
  debugPrint('SUPABASE_URL = $supabaseUrl');
  debugPrint(
    'SUPABASE_PUBLISHABLE_KEY starts with = ${supabasePublishableKey.isNotEmpty ? supabasePublishableKey.substring(0, 12) : "EMPTY"}',
  );
  if (SupabaseConfig.isPlaceholder) {
    debugPrint(
      '⚠️ Using placeholder config. Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY (e.g. .env + run_web.sh or --dart-define).',
    );
  }
  debugPrint('========================================================');

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabasePublishableKey,
    authOptions: kIsWeb
        ? const FlutterAuthClientOptions(authFlowType: AuthFlowType.implicit)
        : const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
  );

  PlacesConfig.warnIfMissing();

  if (!kIsWeb) {
    try {
      final notificationService = NotificationService();
      await notificationService.initialize();
    } catch (e) {
      debugPrint('Warning: Notification service initialization failed: $e');
    }
  }

  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('he'), Locale('en')],
      path: 'assets/translations',
      fallbackLocale: const Locale('he'),
      startLocale: const Locale('he'),
      child: const ProviderScope(
        child: ParkingTradeApp(),
      ),
    ),
  );
}

class ParkingTradeApp extends ConsumerWidget {
  const ParkingTradeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isRtl = context.locale.languageCode == 'he';
    final router = ref.watch(goRouterProvider);

    return MaterialApp.router(
      title: 'Parking Trade',
      theme: AppTheme.light(),
      debugShowCheckedModeBanner: false,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      builder: (context, child) => Directionality(
        textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
        child: child!,
      ),
      routerConfig: router,
    );
  }
}
