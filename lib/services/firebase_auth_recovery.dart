import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'api_service.dart';

/// Firebase session management, custom-token based.
///
/// Anonymous auth is DISABLED in the Firebase console
/// (admin-restricted-operation), but every Firestore/RTDB rule reads
/// `auth != null`. Every `signInAnonymously()` call in the app was
/// therefore dead code that produced its own Crashlytics group and left
/// the client without a session — which is what turned chat, the GPS
/// mirrors and the verification stream into the permission-denied crash
/// groups that dominate the dashboard (400+ events).
///
/// The working path: the app's own JWT is exchanged at the backend
/// (`POST /auth/firebase-token`) for a Firebase custom token, and the
/// client signs in with THAT. No JWT (signed-out user) or a 503 from the
/// mint simply means "no Firebase today": callers must degrade to their
/// backend polling/SSE fallbacks, never crash-loop.
class FirebaseAuthRecovery {
  FirebaseAuthRecovery._();

  static Future<bool>? _inFlight;
  static DateTime _lastAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Minimum gap between attempts. Several listeners fail at the same
  /// instant when a session dies, and each one calls this — without the
  /// cooldown they would stampede the backend.
  static const Duration _cooldown = Duration(seconds: 30);

  /// True when a Firebase session is active right now.
  static bool get hasSession => FirebaseAuth.instance.currentUser != null;

  /// Ensure a Firebase session exists, minting a custom token when needed.
  ///
  /// Concurrent callers share a single attempt. Repeat calls inside the
  /// cooldown are skipped and report the current state instead.
  static Future<bool> ensureSignedIn() {
    final existing = _inFlight;
    if (existing != null) return existing;

    if (FirebaseAuth.instance.currentUser != null) {
      return Future.value(true);
    }
    if (DateTime.now().difference(_lastAttempt) < _cooldown) {
      return Future.value(false);
    }

    final attempt = _signIn();
    _inFlight = attempt;
    return attempt.whenComplete(() => _inFlight = null);
  }

  /// Legacy name — every old "recycle the anonymous session" call site
  /// routes here now.
  static Future<bool> refreshAnonymousSession() => ensureSignedIn();

  static Future<bool> _signIn() async {
    _lastAttempt = DateTime.now();
    final auth = FirebaseAuth.instance;
    try {
      final token = await ApiService.getFirebaseToken();
      if (token == null || token.isEmpty) {
        debugPrint('[AuthRecovery] no custom token (signed out or mint '
            'unavailable) — Firebase stays offline, fallbacks carry');
        return false;
      }
      await auth.signInWithCustomToken(token);
      debugPrint('[AuthRecovery] Firebase session established '
          '(uid=${auth.currentUser?.uid})');
      return auth.currentUser != null;
    } catch (e) {
      debugPrint('[AuthRecovery] custom-token sign-in failed: $e');
      return false;
    }
  }
}
