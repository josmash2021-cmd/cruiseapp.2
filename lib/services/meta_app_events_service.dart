import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:flutter/foundation.dart';

/// Meta/Facebook App Events — campaign measurement for driver acquisition.
///
/// Both platforms now: Android auto-initializes from the manifest meta-data
/// (App ID in strings.xml, Client Token via the META_CLIENT_TOKEN manifest
/// placeholder), iOS from the Info.plist entries (App ID / Display Name /
/// Client Token). Web is the only platform gated off.
class MetaAppEventsService {
  MetaAppEventsService._();

  static final FacebookAppEvents _events = FacebookAppEvents();

  /// Fired once when a driver finishes the initial registration flow, after
  /// the backend confirmed the last step. Never throws and never blocks
  /// signup: attribution logging failing must not abort registration.
  static Future<void> logDriverRegistrationComplete(String method) async {
    if (kIsWeb) return;
    try {
      await _events.logCompletedRegistration(registrationMethod: method);
    } catch (e) {
      debugPrint('⚠️ Meta App Events log failed (non-blocking): $e');
    }
  }
}
