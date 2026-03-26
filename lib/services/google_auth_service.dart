import 'package:flutter/foundation.dart';
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
  Future<bool> signIn({String role = 'rider'}) async {
    try {
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
      }

      AnalyticsService.instance.logLogin('google');
      return true;
    } catch (e) {
      debugPrint('[GoogleAuth] Error: $e');
      return false;
    }
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
  }
}
