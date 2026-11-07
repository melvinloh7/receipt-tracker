import 'dart:async';

import 'package:google_sign_in/google_sign_in.dart';

import '../config.dart';

/// Google sign-in for the dashboard account, plus Drive and Sheets access.
class GoogleAuth {
  GoogleAuth._();
  static final GoogleAuth instance = GoogleAuth._();

  static const scopes = <String>[
    'https://www.googleapis.com/auth/drive',
    'https://www.googleapis.com/auth/spreadsheets',
  ];

  final GoogleSignIn _signIn = GoogleSignIn.instance;
  final _changes = StreamController<GoogleSignInAccount?>.broadcast();
  GoogleSignInAccount? _user;
  bool _initialized = false;

  GoogleSignInAccount? get user => _user;
  Stream<GoogleSignInAccount?> get userChanges => _changes.stream;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _signIn.initialize(
      serverClientId: AppConfig.webClientId.isEmpty ? null : AppConfig.webClientId,
    );
    _signIn.authenticationEvents.listen((event) {
      _user = switch (event) {
        GoogleSignInAuthenticationEventSignIn() => event.user,
        GoogleSignInAuthenticationEventSignOut() => null,
      };
      _changes.add(_user);
    }, onError: (Object e) => _changes.addError(e));

    final attempt = _signIn.attemptLightweightAuthentication();
    if (attempt != null) {
      try {
        await attempt;
      } catch (_) {
        // Not signed in yet; the user signs in from Settings.
      }
    }
  }

  /// Interactive sign-in, then asks for Drive + Sheets access.
  Future<void> signIn() async {
    final user = await _signIn.authenticate(scopeHint: scopes);
    _user = user;
    _changes.add(user);
    await user.authorizationClient.authorizeScopes(scopes);
  }

  Future<void> signOut() async {
    await _signIn.signOut();
    _user = null;
    _changes.add(null);
  }

  /// Authorization headers for Google API calls.
  Future<Map<String, String>> headers() async {
    final user = _user;
    if (user == null) {
      throw StateError('Not signed in to Google. Sign in from Settings.');
    }
    final existing = await user.authorizationClient.authorizationHeaders(scopes);
    if (existing != null) return existing;
    await user.authorizationClient.authorizeScopes(scopes);
    final granted = await user.authorizationClient.authorizationHeaders(scopes);
    if (granted == null) {
      throw StateError('Google access to Drive and Sheets was not granted.');
    }
    return granted;
  }
}
