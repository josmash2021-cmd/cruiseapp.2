import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/env.dart';

/// Service to send and verify OTP codes via Twilio Verify API.
///
/// Uses the Verify API (not basic Messaging) — benefits:
/// - No "Sent from your Twilio trial account" prefix
/// - No A2P 10DLC registration required
/// - Twilio generates the code automatically
/// - Code expiry handled by Twilio

class SmsService {
  // ╔═══════════════════════════════════════════════════════════╗
  // ║  TWILIO CREDENTIALS                                      ║
  // ╚═══════════════════════════════════════════════════════════╝
  static const String _accountSid = Env.twilioAccountSid;
  static const String _authToken = Env.twilioAuthToken;
  static const String _serviceSid = Env.twilioServiceSid;

  static String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$_accountSid:$_authToken'))}';

  /// Returns `true` if Twilio credentials have been configured.
  static bool get isConfigured =>
      _accountSid.startsWith('AC') && _serviceSid.startsWith('VA');

  /// Sends a verification code via SMS to [toPhone].
  /// Twilio generates the code automatically.
  /// Returns a result record: `(ok: bool, trialBlocked: bool)`.
  static Future<({bool ok, bool trialBlocked})> sendVerificationCode({
    required String toPhone,
  }) async {
    if (!isConfigured) {
      debugPrint('⚠️  Twilio Verify NOT configured.');
      return (ok: false, trialBlocked: false);
    }

    final url = Uri.parse(
      'https://verify.twilio.com/v2/Services/$_serviceSid/Verifications',
    );

    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': _authHeader,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {'To': toPhone, 'Channel': 'sms'},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 201 || response.statusCode == 200) {
        debugPrint('✅ Verification SMS sent to $toPhone');
        return (ok: true, trialBlocked: false);
      } else {
        debugPrint(
          '❌ Twilio Verify error ${response.statusCode}: ${response.body}',
        );
        // Error 21608 = trial account cannot send to unverified number
        // Error 60203 = Max send attempts reached
        // Error 60212 = Too many attempts, wait before retrying
        final body = response.body.toLowerCase();
        final isTrialBlock =
            body.contains('21608') ||
            body.contains('unverified') ||
            body.contains('not a valid phone number');
        final errorMsg = jsonDecode(response.body)['message'] ?? response.body;
        debugPrint('📱 Twilio error detail: $errorMsg');
        return (ok: false, trialBlocked: isTrialBlock);
      }
    } catch (e) {
      debugPrint('❌ Verification send failed: $e');
      return (ok: false, trialBlocked: false);
    }
  }

  /// Checks the [code] entered by the user for [toPhone].
  /// Returns `true` if the code is correct (status == "approved").
  static Future<bool> checkVerificationCode({
    required String toPhone,
    required String code,
  }) async {
    if (!isConfigured) {
      debugPrint('⚠️  Twilio Verify NOT configured.');
      return false;
    }

    final url = Uri.parse(
      'https://verify.twilio.com/v2/Services/$_serviceSid/VerificationCheck',
    );

    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': _authHeader,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {'To': toPhone, 'Code': code},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final status = data['status'];
        debugPrint('🔑 Verification status: $status');
        return status == 'approved';
      } else {
        debugPrint(
          '❌ Verify check error ${response.statusCode}: ${response.body}',
        );
        return false;
      }
    } catch (e) {
      debugPrint('❌ Verify check failed: $e');
      return false;
    }
  }
}
