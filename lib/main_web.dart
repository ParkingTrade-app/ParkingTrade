// Web entry point. Optional Firebase web config enables browser push (FCM).
// Use: flutter run -d chrome -t lib/main_web.dart
//      flutter build web -t lib/main_web.dart

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/firebase_options_web.dart';
import 'config/sentry_config.dart';
import 'config/supabase_config.dart';
import 'theme/app_theme.dart';
import 'services/auth_service.dart';
import 'services/notification_service_web.dart';
import 'screens/auth/phone_auth_screen.dart';
import 'screens/auth/create_building_screen.dart';
import 'screens/auth/not_registered_screen.dart';
import 'screens/building/pending_approval_screen.dart';
import 'screens/building/rejected_screen.dart';
import 'screens/spots/parking_spots_screen.dart';
import 'screens/admin/admin_dashboard_screen.dart';
import 'models/profile.dart';

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
  // Set up error handlers to catch and display errors. If Sentry is
  // configured, SentryFlutter.init() already installed handlers that report
  // to Sentry — chain ours after theirs instead of overwriting them, so both
  // the debug logging below and Sentry's reporting run.
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    previousOnError?.call(details);
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exception}');
    debugPrint('Stack: ${details.stack}');
  };

  // Handle async errors
  final previousPlatformOnError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    previousPlatformOnError?.call(error, stack);
    debugPrint('PlatformDispatcher error: $error');
    debugPrint('Stack: $stack');
    return true;
  };

  try {
    WidgetsFlutterBinding.ensureInitialized();
    await EasyLocalization.ensureInitialized();
    debugPrint('### MAIN STARTED (web) ###');

    if (!SupabaseConfig.isConfigured) {
      runApp(const ErrorApp(
        'Supabase configuration is missing.\n\n'
        'Please set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY\n'
        '(or SUPABASE_ANON_KEY for backward compatibility)\n'
        'via .env + run_web.sh or --dart-define.',
      ));
      return;
    }

    const supabaseUrl = SupabaseConfig.supabaseUrl;
    final supabasePublishableKey = SupabaseConfig.supabasePublishableKey;
    debugPrint('Supabase URL = $supabaseUrl');
    if (SupabaseConfig.isPlaceholder) {
      debugPrint(
        '⚠️ Using placeholder Supabase config. Edit .env with real URL and publishable key (Supabase Dashboard → Project Settings → API).',
      );
    }

    try {
      await Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabasePublishableKey, // Supabase SDK still uses 'anonKey' parameter name
      );
    } catch (e) {
      runApp(ErrorApp(
        'Failed to initialize Supabase:\n\n$e\n\n'
        'Please check your SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY.',
      ));
      return;
    }

    // Handle the OAuth PKCE callback: when Google redirects back with
    // ?code=… in the URL, exchange the code for a session so it is stored in
    // localStorage.  Without this call the "Code verifier could not be found"
    // error occurs because the Supabase client hasn't yet exchanged the code.
    // The SDK's onAuthStateChange will fire signedIn once this completes.
    //
    // We skip the exchange if a valid session already exists — this prevents
    // the "Code verifier could not be found" console noise that occurs when the
    // page is reloaded after the code has already been consumed.
    if (kIsWeb) {
      final uri = Uri.base;
      final hasCode = uri.queryParameters.containsKey('code');
      final alreadySignedIn =
          Supabase.instance.client.auth.currentSession != null;
      if (hasCode && !alreadySignedIn) {
        try {
          await Supabase.instance.client.auth.getSessionFromUrl(uri);
        } catch (e) {
          // The code may have already been exchanged (e.g. fast double-load).
          // This is non-fatal — the auth state listener will route correctly.
          debugPrint('OAuth code exchange skipped or failed: $e');
        }
      }
    }

    if (FirebaseOptionsWeb.isConfigured) {
      try {
        await Firebase.initializeApp(options: FirebaseOptionsWeb.options);
        await WebNotificationService().initialize();
      } catch (e) {
        debugPrint('Firebase/Web push init failed: $e');
        // Continue even if Firebase fails - it's optional
      }
    }

    runApp(
      EasyLocalization(
        supportedLocales: const [Locale('he'), Locale('en')],
        path: 'assets/translations',
        fallbackLocale: const Locale('he'),
        startLocale: const Locale('he'),
        child: const ParkingTradeApp(),
      ),
    );
  } catch (e, stackTrace) {
    debugPrint('Fatal error in main: $e');
    debugPrint('Stack: $stackTrace');
    runApp(ErrorApp('Fatal error:\n\n$e'));
  }
}

class ParkingTradeApp extends StatelessWidget {
  const ParkingTradeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Parking Trade',
      theme: AppTheme.light(),
      debugShowCheckedModeBanner: false,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      home: const AuthWrapper(),
      routes: {
        '/auth': (context) => const PhoneAuthScreen(),
        '/setup': (context) => CreateBuildingScreen(
              onCreated: () => Navigator.of(context)
                  .pushNamedAndRemoveUntil('/admin-dashboard', (route) => false),
            ),
        '/not-registered': (context) => const NotRegisteredScreen(),
        '/pending-approval': (context) => const PendingApprovalScreen(),
        '/rejected': (context) => const RejectedScreen(),
        '/home': (context) => const ParkingSpotsScreen(),
        '/admin-dashboard': (context) => const AdminDashboardScreen(),
      },
    );
  }
}

class ErrorApp extends StatelessWidget {
  final String message;

  const ErrorApp(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Parking Trade - Error',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Colors.red,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Configuration Error',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  final _authService = AuthService();
  bool _isLoading = true;
  bool _isSetupMode = false;
  // Guard: only one _navigateBasedOnProfile() call may run at a time.
  // Without this, _checkAuth() and _handleAuthChange(initialSession) both
  // fire on startup when a persisted session exists, causing two concurrent
  // navigation calls. The second one can lose the race and leave _isLoading
  // stuck at true if the widget has already navigated away.
  bool _navigating = false;
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _isSetupMode = _detectSetupMode();
    _checkAuth();
    _authSubscription = _authService.authStateChanges.listen(
      (state) {
        // Handle async operation properly to avoid promise rejection
        _handleAuthChange(state).catchError((error) {
          if (mounted) {
            debugPrint('Error handling auth change: $error');
            // Always clear the spinner even on unexpected errors.
            setState(() => _isLoading = false);
          }
        });
      },
      onError: (error) {
        if (mounted) {
          debugPrint('Auth state stream error: $error');
          setState(() => _isLoading = false);
        }
      },
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  /// Returns true when the URL contains `mode=setup` (web only).
  bool _detectSetupMode() {
    if (!kIsWeb) return false;
    try {
      final uri = Uri.base;
      return uri.queryParameters['mode'] == 'setup';
    } catch (_) {
      return false;
    }
  }

  Future<void> _checkAuth() async {
    // Use currentSession (not just currentUser) so we confirm a valid,
    // persisted session exists before bypassing the phone auth screen.
    final session = _authService.currentSession;
    if (session != null) {
      // If we are in setup mode, stay on the setup screen — don't route away.
      if (_isSetupMode) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      await _navigateBasedOnProfile();
    } else {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleAuthChange(AuthState state) async {
    if (state.event == AuthChangeEvent.signedIn ||
        state.event == AuthChangeEvent.initialSession ||
        state.event == AuthChangeEvent.tokenRefreshed) {
      // On app restart with a persisted session the SDK fires initialSession.
      // tokenRefreshed fires when the access token is silently renewed.
      // In all these cases we want to route based on the user's profile.
      if (_authService.currentSession != null) {
        // Sync Google display name so the dashboard always shows the real
        // name from the user's Google account. Run on signedIn (fresh login)
        // and initialSession (page reload with stored session) so the name
        // is corrected even without a new login.
        if (state.event == AuthChangeEvent.signedIn ||
            state.event == AuthChangeEvent.initialSession) {
          await _authService.syncGoogleDisplayName();
        }
        // If setup mode is active, stay on the setup screen — don't route away.
        if (_isSetupMode) {
          if (mounted) setState(() => _isLoading = false);
          return;
        }
        await _navigateBasedOnProfile();
      } else if (state.event == AuthChangeEvent.initialSession) {
        // initialSession fired but session is null → no stored session, show auth.
        if (mounted) setState(() => _isLoading = false);
      }
    } else if (state.event == AuthChangeEvent.signedOut) {
      if (mounted) {
        setState(() => _isLoading = false);
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/auth',
          (route) => false,
        );
      }
    }
  }

  Future<void> _navigateBasedOnProfile() async {
    // Prevent concurrent navigation calls (e.g. _checkAuth + initialSession
    // both firing on startup). Only the first caller proceeds; subsequent
    // calls return immediately so _isLoading is not double-cleared after the
    // widget has already navigated away.
    if (_navigating) return;
    _navigating = true;

    try {
      final profile = await _authService.getCurrentProfile();

      if (!mounted) return;

      // Google-OAuth users who have no profile or no apartment assigned yet
      // are either brand-new admins or need to complete setup.
      // Route them to the setup screen if they authenticated via Google;
      // otherwise show the "not registered" screen (they need an admin to
      // pre-authorise their unit).
      if (profile == null || profile.apartmentId == null) {
        if (_authService.isGoogleUser) {
          // Google-OAuth user with no building/profile → send to setup flow.
          Navigator.of(context).pushReplacementNamed('/setup');
        } else {
          Navigator.of(context).pushReplacementNamed('/not-registered');
        }
        return;
      }

      // Profile is linked to an apartment — route based on role then status.
      if (profile.isAdmin) {
        // Building admins always go to the Admin Dashboard.
        Navigator.of(context).pushReplacementNamed('/admin-dashboard');
      } else if (profile.status == ProfileStatus.pending) {
        Navigator.of(context).pushReplacementNamed('/pending-approval');
      } else if (profile.status == ProfileStatus.rejected) {
        Navigator.of(context).pushReplacementNamed('/rejected');
      } else {
        // approved regular member → go to parking spots
        Navigator.of(context).pushReplacementNamed('/home');
      }
    } catch (e) {
      debugPrint('Error navigating based on profile: $e');
      if (!mounted) return;
      final user = _authService.currentUser;
      if (user == null) {
        Navigator.of(context).pushReplacementNamed('/auth');
      } else {
        // Authenticated but profile fetch failed — treat as not registered.
        Navigator.of(context).pushReplacementNamed('/not-registered');
      }
    } finally {
      // Always clear the loading spinner, even if an unhandled exception
      // escapes the catch block — this is what previously caused the
      // infinite spinner bug.
      _navigating = false;
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Admin-onboarding mode: ?mode=setup
    // Show the building-creation form. On success, navigate to the dashboard.
    if (_isSetupMode) {
      return CreateBuildingScreen(
        onCreated: () {
          if (mounted) {
            setState(() => _isSetupMode = false);
            Navigator.of(context).pushNamedAndRemoveUntil(
              '/admin-dashboard',
              (route) => false,
            );
          }
        },
      );
    }

    return const PhoneAuthScreen();
  }
}
