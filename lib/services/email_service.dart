import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/env.dart';

/// Service to send verification codes via EmailJS.
///
/// Setup (one-time — takes ~5 minutes):
/// 1. Go to https://www.emailjs.com/ and create a FREE account.
/// 2. In the dashboard, go to "Email Services" → "Add New Service".
///    - Choose your email provider (Gmail, Outlook, etc.).
///    - Connect your email account and note the **Service ID** (e.g. "service_abc123").
/// 3. Go to "Email Templates" → "Create New Template".
///    - Subject: "Your Cruise verification code"
///    - Body:
///        Hi {{to_name}},
///
///        Your Cruise verification code is: {{code}}
///
///        This code expires in 10 minutes.
///
///    - Set "To Email" to {{to_email}}
///    - Save and note the **Template ID** (e.g. "template_xyz789").
/// 4. Go to "Account" → "General" and copy your **Public Key**.
/// 5. Paste the three values below.

class EmailService {
  // ╔═══════════════════════════════════════════════════════════╗
  // ║  PASTE YOUR EMAILJS CREDENTIALS HERE                     ║
  // ╚═══════════════════════════════════════════════════════════╝
  static const String _serviceId = Env.emailjsServiceId;
  static const String _templateId = Env.emailjsTemplateId;
  static const String _publicKey = Env.emailjsPublicKey;
  static const String _privateKey = Env.emailjsPrivateKey;

  static const String _apiUrl = 'https://api.emailjs.com/api/v1.0/email/send';

  /// Returns `true` if EmailJS credentials have been configured.
  static bool get isConfigured =>
      _serviceId != 'YOUR_SERVICE_ID' &&
      _templateId != 'YOUR_TEMPLATE_ID' &&
      _publicKey != 'YOUR_PUBLIC_KEY' &&
      _privateKey != 'YOUR_PRIVATE_KEY';

  /// Sends [code] to [toEmail]. Returns `true` on success.
  static Future<bool> sendVerificationCode({
    required String toEmail,
    required String code,
    String toName = 'Cruise User',
  }) async {
    if (kDebugMode) {
      debugPrint('📧 EmailService.sendVerificationCode called for: $toEmail');
      debugPrint('🔧 isConfigured: $isConfigured');
      debugPrint('🔧 serviceId: ${_serviceId.substring(0, _serviceId.length > 8 ? 8 : _serviceId.length)}...');
      debugPrint('🔧 templateId: ${_templateId.substring(0, _templateId.length > 8 ? 8 : _templateId.length)}...');
      debugPrint('🔧 publicKey: ${_publicKey.substring(0, _publicKey.length > 8 ? 8 : _publicKey.length)}...');
    }

    // If not configured, fall back to debug-only mode
    if (!isConfigured) {
      debugPrint('⚠️ EmailJS NOT configured — code only in console.');
      debugPrint('🔑 Verification code for $toEmail: $code');
      return false;
    }

    try {
      final payload = {
        'service_id': _serviceId,
        'template_id': _templateId,
        'user_id': _publicKey,
        'accessToken': _privateKey,
        'template_params': {
          'to_email': toEmail,
          'to_name': toName,
          'name': toName,
          'code': code,
          'verification_code': code,
        },
      };

      if (kDebugMode) {
        debugPrint('📧 EmailJS payload: ${jsonEncode(payload)}');
      }

      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        debugPrint('✅ Verification code sent to $toEmail');
        return true;
      } else {
        debugPrint('❌ EmailJS error ${response.statusCode}: ${response.body}');
        debugPrint('❌ EmailJS request: service=$_serviceId, template=$_templateId');
        debugPrint('🔑 Fallback — code for $toEmail: $code');
        return false;
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Email send failed: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      debugPrint('🔑 Fallback — code for $toEmail: $code');
      return false;
    }
  }
}
