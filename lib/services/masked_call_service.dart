import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_service.dart';

/// Masked rider↔driver calling.
///
/// Fetches a short-lived masked contact (company Twilio number + 6-digit
/// extension) from the backend and launches the native dialer with it, so
/// neither side ever sees the other's real phone number. The backend's
/// /voice/bridge webhook bridges the call to the counterparty with the
/// Twilio number as callerId.
class MaskedCallService {
  MaskedCallService._();

  /// Fetch the masked contact for [tripId] and launch the dialer.
  /// [role] is the CALLER's role: 'rider' or 'driver'.
  /// Returns true if the dialer was launched, false otherwise.
  static Future<bool> callCounterparty({
    required int tripId,
    required String role,
  }) async {
    try {
      final res = await ApiService.getMaskedContact(tripId, role: role)
          .timeout(const Duration(seconds: 12));
      final phone = (res['phone_number'] ?? '').toString();
      final ext = (res['extension'] ?? '').toString();
      if (phone.isEmpty || ext.isEmpty) {
        debugPrint('[MaskedCall] no masked contact for trip=$tripId: ${res['error']}');
        return false;
      }
      // Commas are 2-second pauses: the dialer waits for the call to connect,
      // then auto-sends the extension as DTMF so the bridge can route it.
      final uri = Uri(scheme: 'tel', path: '$phone,,,$ext');
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    } catch (e) {
      debugPrint('[MaskedCall] failed for trip=$tripId: $e');
      return false;
    }
  }
}
