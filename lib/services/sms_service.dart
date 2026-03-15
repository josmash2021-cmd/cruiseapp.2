import 'package:flutter/foundation.dart';
import 'api_service.dart';

/// Service to send and verify OTP codes via the backend proxy.
///
/// Calls /auth/send-otp and /auth/verify-otp on the Cruise backend.
/// Twilio credentials stay server-side — never exposed in the app bundle.

class SmsService {
  /// Always true — the backend handles configuration checks.
  static bool get isConfigured => true;

  /// Sends a verification code via SMS to [toPhone] through the backend.
  /// Returns a result record: `(ok: bool, trialBlocked: bool)`.
  static Future<({bool ok, bool trialBlocked})> sendVerificationCode({
    required String toPhone,
  }) async {
    try {
      await ApiService.sendOtp(phone: toPhone);
      debugPrint('✅ OTP sent via backend to $toPhone');
      return (ok: true, trialBlocked: false);
    } on ApiException catch (e) {
      debugPrint('❌ send-otp backend error ${e.statusCode}: ${e.message}');
      if (e.statusCode == 503) {
        return (ok: false, trialBlocked: false);
      }
      return (ok: false, trialBlocked: false);
    } catch (e) {
      debugPrint('❌ send-otp failed: $e');
      return (ok: false, trialBlocked: false);
    }
  }

  /// Checks the [code] entered by the user for [toPhone] through the backend.
  /// Returns `true` if the code is correct.
  static Future<bool> checkVerificationCode({
    required String toPhone,
    required String code,
  }) async {
    try {
      final valid = await ApiService.verifyOtp(phone: toPhone, code: code);
      debugPrint('🔑 OTP verify result: $valid');
      return valid;
    } catch (e) {
      debugPrint('❌ verify-otp failed: $e');
      return false;
    }
  }
}
