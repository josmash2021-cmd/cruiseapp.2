import '../utils/app_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'api_service.dart';
import 'analytics_service.dart';
import 'user_session.dart';

/// Handles Apple Sign-In flow and backend token exchange.
class AppleAuthService {
  AppleAuthService._();
  static final AppleAuthService instance = AppleAuthService._();

  /// Whether Apple Sign-In is available on this device.
  bool get isAvailable => AppPlatform.isIOS || AppPlatform.isMacOS;

  /// Returns the Apple account email without calling the backend.
  /// Used on the Create Account screen to extract the email for registration.
  Future<String?> getEmail() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      return credential.email;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      debugPrint('[AppleAuth] getEmail error: $e');
      return null;
    } catch (e) {
      debugPrint('[AppleAuth] getEmail error: $e');
      return null;
    }
  }

  /// Returns `{email, idToken, firstName, lastName}` for the signed-in Apple
  /// account, without calling the backend. Used by the social registration
  /// flow so we have the idToken ready after OTP verification.
  /// NOTE: Apple only provides email on the first authentication. On subsequent
  /// authentications `email` will be null — callers must handle this case.
  Future<Map<String, String?>?> getCredential() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      return {
        'email': credential.email,
        'idToken': credential.identityToken,
        'firstName': credential.givenName,
        'lastName': credential.familyName,
      };
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      debugPrint('[AppleAuth] getCredential error: $e');
      rethrow;
    } catch (e) {
      debugPrint('[AppleAuth] getCredential error: $e');
      rethrow;
    }
  }

  /// Returns true on success, false on cancel/failure.
  /// When [loginOnly] is true, rejects if no account exists (login screen).
  Future<bool> signIn({String role = 'rider', bool loginOnly = false}) async =>
      await signInWithResult(role: role, loginOnly: loginOnly) != null;

  /// Same flow as [signIn] but returns the backend payload
  /// `{ access_token, refresh_token, user }` so the caller can route by
  /// account state (e.g. the rider welcome screen sends brand-new Apple
  /// accounts through the name flow). Returns null on cancel/failure.
  Future<Map<String, dynamic>?> signInWithResult({
    String role = 'rider',
    bool loginOnly = false,
  }) async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      final idToken = credential.identityToken;
      if (idToken == null) {
        debugPrint('[AppleAuth] No identity token received');
        return null;
      }

      final result = await ApiService.socialAuth(
        provider: 'apple',
        idToken: idToken,
        firstName: credential.givenName,
        lastName: credential.familyName,
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
      } else {
        // FIX: If the backend returns a token but no user object, the session
        // is incomplete. Without a saved user, SplashScreen will redirect back
        // to the welcome screen because isLoggedInLocal() returns false.
        // This was the root cause of the Apple Sign-In loop reported by App
        // Store Review: user tapped Sign in with Apple, appeared to succeed,
        // but was immediately returned to the sign-in screen.
        debugPrint('[AppleAuth] socialAuth succeeded but user object is missing — treating as failure');
        return null;
      }

      AnalyticsService.instance.logLogin('apple');
      return result;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      debugPrint('[AppleAuth] Auth error: $e');
      rethrow;
    } catch (e) {
      debugPrint('[AppleAuth] Error: $e');
      rethrow;
    }
  }
}
