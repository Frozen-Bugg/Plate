import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

/// The Supabase session, starting with the current one.
final authSessionProvider = StreamProvider<Session?>((ref) async* {
  final auth = Supabase.instance.client.auth;
  yield auth.currentSession;
  yield* auth.onAuthStateChange.map((state) => state.session);
});

final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(authSessionProvider).value?.user ??
      Supabase.instance.client.auth.currentUser;
});

final authServiceProvider =
    Provider((ref) => AuthService(Supabase.instance.client.auth));

/// Native sign-in flows that hand an ID token to Supabase.
class AuthService {
  AuthService(this._auth);

  final GoTrueClient _auth;
  Future<void>? _googleInit;

  /// Sign in with Apple is offered on iOS only; Android would need a web flow.
  static bool get appleAvailable => Platform.isIOS;

  Future<void> signInWithApple() async {
    final rawNonce = _randomNonce();
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
    );
    final idToken = credential.identityToken;
    if (idToken == null) {
      throw const AuthException('Apple did not return an identity token.');
    }
    await _auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: idToken,
      nonce: rawNonce,
    );
  }

  Future<void> signInWithGoogle() async {
    final google = GoogleSignIn.instance;
    await (_googleInit ??= google.initialize(
      clientId: Platform.isIOS ? AppConfig.googleIosClientId : null,
      serverClientId: AppConfig.googleWebClientId,
    ));
    final account = await google.authenticate();
    const scopes = ['email', 'profile'];
    final authorization =
        await account.authorizationClient.authorizationForScopes(scopes) ??
            await account.authorizationClient.authorizeScopes(scopes);
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const AuthException('Google did not return an ID token.');
    }
    await _auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: authorization.accessToken,
    );
  }

  Future<void> signInWithPassword(String email, String password) =>
      _auth.signInWithPassword(email: email.trim(), password: password);

  /// Creates an account. Returns false when Supabase requires the address to be
  /// confirmed first, in which case no session exists yet.
  Future<bool> signUpWithPassword(String email, String password) async {
    final response =
        await _auth.signUp(email: email.trim(), password: password);
    return response.session != null;
  }

  Future<void> signOut() async {
    if (_googleInit != null) {
      await GoogleSignIn.instance.signOut();
    }
    await _auth.signOut();
  }

  static String _randomNonce([int length = 32]) {
    const chars =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => chars[random.nextInt(chars.length)])
        .join();
  }
}

/// A user-facing message for a failed sign-in, or null if the user cancelled.
String? describeAuthError(Object error) => switch (error) {
      SignInWithAppleAuthorizationException(
        code: AuthorizationErrorCode.canceled
      ) =>
        null,
      GoogleSignInException(code: GoogleSignInExceptionCode.canceled) => null,
      // Network failures arrive as a subclass of AuthException carrying a raw
      // ClientException message, so catch them before the general case.
      AuthRetryableFetchException() =>
        'Can\'t reach the server. Check your connection and try again.',
      AuthException(:final message) => message,
      GoogleSignInException(:final description) =>
        description ?? 'Google sign-in failed. Try again.',
      SignInWithAppleException() => 'Apple sign-in failed. Try again.',
      _ => 'Something went wrong. Check your connection and try again.',
    };
