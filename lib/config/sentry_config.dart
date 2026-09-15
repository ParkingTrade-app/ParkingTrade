// Sentry config from --dart-define (optional; if DSN is not set, error
// tracking is disabled and the app behaves exactly as it did before this
// integration existed — same pattern as FirebaseOptionsWeb.isConfigured).
// Get the DSN from Sentry -> Project Settings -> Client Keys (DSN).

class SentryConfig {
  static const String dsn = String.fromEnvironment(
    'SENTRY_DSN',
    defaultValue: '',
  );

  // 'development' | 'staging' | 'production'. Set via --dart-define=APP_ENV=...
  // in CI; defaults to 'development' for local runs.
  static const String environment = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'development',
  );

  static bool get isConfigured => dsn.isNotEmpty;
}
