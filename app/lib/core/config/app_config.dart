/// Build-time configuration, passed with
/// `flutter run --dart-define-from-file=config/dev.json`.
/// See config/dev.example.json for the keys.
abstract final class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const powersyncUrl = String.fromEnvironment('POWERSYNC_URL');

  /// OAuth client IDs for native Google sign-in. The web client ID is the one
  /// configured in Supabase → Auth → Google; the iOS one comes from Google Cloud.
  static const googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
  static const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  /// Keys the app cannot start without.
  static List<String> get missingRequired => [
        if (supabaseUrl.isEmpty) 'SUPABASE_URL',
        if (supabasePublishableKey.isEmpty) 'SUPABASE_PUBLISHABLE_KEY',
      ];

  /// Without a PowerSync instance the app still runs: everything is logged to
  /// the local database and nothing leaves the phone.
  static bool get syncConfigured => powersyncUrl.isNotEmpty;

  static bool get googleSignInConfigured => googleWebClientId.isNotEmpty;
}
