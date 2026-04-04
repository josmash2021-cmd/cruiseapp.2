import 'dart:io';
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
  bool get isAvailable => Platform.isIOS || Platform.isMacOS;

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

  /// Returns true on success, false on cancel/failure.
  /// When [loginOnly] is true, rejects if no account exists (login screen).
  Future<bool> signIn({String role = 'rider', bool loginOnly = false}) async {
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
        return false;
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
      }

      AnalyticsService.instance.logLogin('apple');
      return true;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return false;
      debugPrint('[AppleAuth] Auth error: $e');
      rethrow;
    } catch (e) {
      debugPrint('[AppleAuth] Error: $e');
      rethrow;
    }
  }
}
