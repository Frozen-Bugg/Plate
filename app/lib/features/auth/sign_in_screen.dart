import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../app/theme.dart';
import '../../app/widgets/plate_icon.dart';
import '../../core/auth/auth_service.dart';
import '../../core/config/app_config.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (error, stack) {
      // The on-screen message is deliberately plain; keep the real cause in the log.
      Logger('auth').warning('sign-in failed', error, stack);
      if (mounted) setState(() => _error = describeAuthError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Returns false and shows a message when the form isn't filled in.
  bool _validate() {
    final problem = switch ((_email.text.trim(), _password.text)) {
      (final email, _) when !email.contains('@') => 'Enter your email address.',
      (_, final password) when password.length < 6 =>
        'Passwords are at least 6 characters.',
      _ => null,
    };
    setState(() => _error = problem);
    return problem == null;
  }

  // On success the router sees the new session and leaves this screen.
  Future<void> _signIn() async {
    if (!_validate()) return;
    await _run(() => ref
        .read(authServiceProvider)
        .signInWithPassword(_email.text, _password.text));
  }

  Future<void> _createAccount() async {
    if (!_validate()) return;
    await _run(() async {
      final signedIn = await ref
          .read(authServiceProvider)
          .signUpWithPassword(_email.text, _password.text);
      if (!signedIn && mounted) {
        setState(() => _notice =
            'Account created. Confirm your email address, then sign in.');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = ref.read(authServiceProvider);
    final pillars = PillarColors.of(context);
    final dark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Row(
                  children: [
                    for (final color in [
                      pillars.train,
                      pillars.body,
                      pillars.move,
                      pillars.fuel,
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: PlateIcon(color: color, size: 16),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  'OVERLOAD',
                  style: theme.textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Training, food, steps and recovery in one loop.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 40),
                if (AuthService.appleAvailable) ...[
                  SignInWithAppleButton(
                    text: 'Continue with Apple',
                    height: 52,
                    style: dark
                        ? SignInWithAppleButtonStyle.white
                        : SignInWithAppleButtonStyle.black,
                    borderRadius: BorderRadius.circular(10),
                    onPressed: _busy ? null : () => _run(auth.signInWithApple),
                  ),
                  const SizedBox(height: 12),
                ],
                if (AppConfig.googleSignInConfigured) ...[
                  OutlinedButton(
                    onPressed: _busy ? null : () => _run(auth.signInWithGoogle),
                    child: const Text('Continue with Google'),
                  ),
                  const SizedBox(height: 24),
                ],
                Text(
                  'Or sign in with your email and password.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                AutofillGroup(
                  child: Column(
                    children: [
                      TextField(
                        controller: _email,
                        enabled: !_busy,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: 'Email'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _signIn(),
                        decoration: const InputDecoration(labelText: 'Password'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _signIn,
                  child: _busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Sign in'),
                ),
                TextButton(
                  onPressed: _busy ? null : _createAccount,
                  child: const Text('Create account'),
                ),
                if (_notice != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _notice!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
