import 'package:flutter/foundation.dart';

import '../utils/app_platform.dart';
import 'package:flutter/services.dart';
import 'prefs_cache.dart';

/// Bridge for driver referral links (`https://<backend>/drive/{code}`).
///
/// Two ways a code arrives:
///  - The app is ALREADY installed: the OS opens the link inside the app
///    (iOS Universal Link / Android App Link). Native captures the intent and
///    pushes the code over the `cruise/referral_link` MethodChannel.
///  - New install (Android): the Play Store keeps our `driver_code=…` in the
///    install referrer; MainActivity reads it once on first launch and pushes
///    it over the same channel. iOS has no install referrer — the landing
///    page offers a copyable code instead.
///
/// The code is persisted under `pending_driver_referral_code` so it survives
/// the gap between link arrival and the driver signup flow (the user may
/// close the app in between). It is cleared once signup redeems it.
///
/// No-op on web and on builds whose native side predates the channel.
class ReferralLinkService {
  ReferralLinkService._();

  static const _channel = MethodChannel('cruise/referral_link');
  static const _pendingKey = 'pending_driver_referral_code';

  static bool _initialized = false;

  /// Install the native→Dart handler and absorb any code that arrived before
  /// Dart was up (native caches it). Call once during heavyInit.
  static Future<void> init() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;
    if (!AppPlatform.isIOS && !AppPlatform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'driverReferralLink') {
        final code = (call.arguments as String?)?.trim().toUpperCase() ?? '';
        if (code.isNotEmpty) await _store(code);
      }
      return null;
    });
    // Codes delivered at process start (cold launch from the link, or the
    // Play install referrer read) were cached natively — collect them now.
    try {
      final pending = await _channel
          .invokeMethod<String>('getPendingDriverCode')
          .timeout(const Duration(seconds: 3));
      final code = pending?.trim().toUpperCase() ?? '';
      if (code.isNotEmpty) await _store(code);
    } on MissingPluginException {
      // Older native build without the channel — fine, nothing to absorb.
    } catch (e) {
      debugPrint('[ReferralLink] pending-code read failed: $e');
    }
  }

  static Future<void> _store(String code) async {
    final prefs = await PrefsCache.instance;
    await prefs.setString(_pendingKey, code);
    debugPrint('[ReferralLink] pending driver code stored');
  }

  /// The referral code waiting to be applied at driver signup, if any.
  static Future<String?> pendingDriverCode() async {
    if (kIsWeb) return null;
    final prefs = await PrefsCache.instance;
    final code = prefs.getString(_pendingKey)?.trim() ?? '';
    return code.isEmpty ? null : code;
  }

  /// Forget the pending code — call it only after a successful redeem, or
  /// the driver would get the same stranger's code re-applied forever.
  static Future<void> clearPendingDriverCode() async {
    if (kIsWeb) return;
    final prefs = await PrefsCache.instance;
    await prefs.remove(_pendingKey);
  }
}
