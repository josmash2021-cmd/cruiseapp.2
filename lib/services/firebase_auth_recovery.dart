import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Recovery for a dead anonymous Firebase session.
///
/// Every `permission-denied` handler in the app follows the same recipe:
/// "the session expired, re-auth and the listener reconnects", implemented
/// as `FirebaseAuth.instance.signInAnonymously()`.
///
/// That call is a NO-OP here. Firebase returns the *existing* anonymous
/// user when one is already signed in — it does not mint a new session. So
/// when the anonymous credential goes bad (revoked refresh token, account
/// wiped server-side, clock skew) the recovery hands the same broken
/// session straight back, every request keeps failing, and the listener
/// errors forever. The rider sees "Connection lost — reconnecting…" that
/// never clears, on full signal.
///
/// The only thing that produces a genuinely new session is signing out
/// first. That is what this does.
class FirebaseAuthRecovery {
  FirebaseAuthRecovery._();

  static Future<bool>? _inFlight;
  static DateTime _lastAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Minimum gap between attempts. Several listeners fail at the same
  /// instant when a session dies, and each one calls this — without the
  /// cooldown they would stampede the auth endpoint.
  static const Duration _cooldown = Duration(seconds: 30);

  /// Force a fresh anonymous session. Returns true when one is active
  /// afterwards.
  ///
  /// Concurrent callers share a single attempt. Repeat calls inside the
  /// cooldown are skipped and report the current state instead.
  static Future<bool> refreshAnonymousSession() {
    final existing = _inFlight;
    if (existing != null) return existing;

    if (DateTime.now().difference(_lastAttempt) < _cooldown) {
      return Future.value(FirebaseAuth.instance.currentUser != null);
    }

    final attempt = _refresh();
    _inFlight = attempt;
    return attempt.whenComplete(() => _inFlight = null);
  }

  static Future<bool> _refresh() async {
    _lastAttempt = DateTime.now();
    final auth = FirebaseAuth.instance;
    try {
      // Only anonymous sessions may be recycled. A real signed-in user
      // hitting permission-denied is a rules problem, and signing them
      // out would be far worse than the error.
      final user = auth.currentUser;
      if (user != null && !user.isAnonymous) {
        debugPrint('[AuthRecovery] signed-in user denied — not touching '
            'their session');
        return true;
      }
      if (user != null) {
        await auth.signOut();
      }
      await auth.signInAnonymously();
      debugPrint('[AuthRecovery] fresh anonymous session established');
      return auth.currentUser != null;
    } catch (e) {
      debugPrint('[AuthRecovery] could not refresh anonymous session: $e');
      return false;
    }
  }
}
