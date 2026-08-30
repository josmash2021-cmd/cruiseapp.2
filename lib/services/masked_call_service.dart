import 'package:flutter/foundation.dart';

import 'api_service.dart';

/// Masked rider↔driver calling, callback mode ("we call you").
///
/// The app asks the backend to ring the CALLER's registered phone via
/// Twilio; when they answer, the /voice/callback webhook bridges them to
/// the counterparty with the company number as callerId. Neither side ever
/// sees the other's real phone number — and nobody sees the old
/// `tel:proxy,,,extension` dialer string.
///
/// (The extension bridge — GET /trips/{id}/masked-contact + tel: dial —
/// still exists server-side for older app builds.)
class MaskedCallService {
  MaskedCallService._();

  /// Place the callback for [tripId]. [role] is the CALLER's role:
  /// 'rider' or 'driver'. Returns true when the call was placed — the
  /// caller's phone will ring within a few seconds.
  static Future<bool> callCounterparty({
    required int tripId,
    required String role,
  }) async {
    try {
      final ok = await ApiService.startCallbackCall(tripId, role: role)
          .timeout(const Duration(seconds: 15));
      if (!ok) {
        debugPrint('[MaskedCall] callback rejected for trip=$tripId');
      }
      return ok;
    } catch (e) {
      debugPrint('[MaskedCall] failed for trip=$tripId: $e');
      return false;
    }
  }
}
