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
    // If not configured, fall back to debug-only mode
    if (!isConfigured) {
      debugPrint('⚠️  EmailJS NOT configured — code only in console.');
      debugPrint('🔑 Verification code for $toEmail: $code');
      return false;
    }

    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'origin': 'http://localhost',
          'User-Agent': 'Mozilla/5.0',
        },
        body: jsonEncode({
          'service_id': _serviceId,
          'template_id': _templateId,
          'user_id': _publicKey,
          'accessToken': _privateKey,
          'template_params': {
            'to_email': toEmail,
            'to_name': toName,
            'code': code,
          },
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('✅ Verification code sent to $toEmail');
        return true;
      } else {
        debugPrint('❌ EmailJS error ${response.statusCode}: ${response.body}');
        debugPrint('🔑 Fallback — code for $toEmail: $code');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Email send failed: $e');
      debugPrint('🔑 Fallback — code for $toEmail: $code');
      return false;
    }
  }
}
