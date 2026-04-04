import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'api_service.dart';
import 'analytics_service.dart';
import 'user_session.dart';

/// Handles Google Sign-In flow and backend token exchange.
class GoogleAuthService {
  GoogleAuthService._();
  static final GoogleAuthService instance = GoogleAuthService._();

  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email']);

  /// Returns true on success, false on cancel/failure.
  /// When [loginOnly] is true, rejects if no account exists (login screen).
  /// Throws on 401 (invalid credentials) so the UI can show the error.
  Future<bool> signIn({String role = 'rider', bool loginOnly = false}) async {
    try {
      // Disconnect previous session to always show account picker
      try { await _googleSignIn.signOut(); } catch (_) {}

      final account = await _googleSignIn.signIn();
      if (account == null) return false; // user cancelled

      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null) {
        debugPrint('[GoogleAuth] No ID token received');
        return false;
      }

      final result = await ApiService.socialAuth(
        provider: 'google',
        idToken: idToken,
        firstName: account.displayName?.split(' ').first,
        lastName: account.displayName?.split(' ').skip(1).join(' '),
        photoUrl: account.photoUrl,
        role: role,
        loginOnly: loginOnly,
      );

      final user = result['user'] as Map<String, dynamic>?;
      if (user != null) {
        await UserSession.saveUser(
          firstName: user['first_name'] ?? '',
          lastName: user['last_name'] ?? '',
          email: user['email'] ?? '',
          phone: user['phone'] as String?,
          photoUrl: user['photo_url'] as String?,
          userId: user['id'] as int?,
          role: user['role'] as String?,
        );
        await UserSession.initPhotoNotifier();
      }

      AnalyticsService.instance.logLogin('google');
      return true;
    } on PlatformException catch (e) {
      debugPrint('[GoogleAuth] PlatformException: ${e.code} - ${e.message}');
      // Re-throw so UI can show error (don't silently swallow)
      rethrow;
    } catch (e) {
      debugPrint('[GoogleAuth] Error: $e');
      // Re-throw API errors (401 etc.) so login screen shows message
      rethrow;
    }
  }

  /// Returns the Google account email without calling the backend.
  /// Used on the Create Account screen to extract the email for registration.
  Future<String?> getEmail() async {
    try {
      try { await _googleSignIn.signOut(); } catch (_) {}
      final account = await _googleSignIn.signIn();
      if (account == null) return null; // user cancelled
      return account.email;
    } catch (e) {
      debugPrint('[GoogleAuth] getEmail error: $e');
      return null;
    }
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
  }
}
