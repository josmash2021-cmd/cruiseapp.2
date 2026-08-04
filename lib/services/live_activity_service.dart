import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_platform.dart';

/// Bridge to the iOS Live Activity (Dynamic Island) — the Cruise logo
/// stays visible while the driver is online and switches to another app.
///
/// iOS-only; every call is a silent no-op on Android/web and on builds
/// where the native side is missing (older installed versions raise
/// MissingPluginException — swallowed, a Live Activity is cosmetic and
/// must never break the online flow). Native side: AppDelegate.swift
/// (channel + ActivityKit manager, iOS 16.2+) and the CruiseLiveActivity
/// widget extension target.
class LiveActivityService {
  LiveActivityService._();

  static const _channel = MethodChannel('cruise/live_activity');

  /// Driver went online — put the Cruise logo in the Dynamic Island.
  static Future<void> startOnline() => _invoke('start', 'online');

  /// Trip accepted / finished — refresh the island's status line.
  static Future<void> updateStatus(String status) =>
      _invoke('update', status);

  /// Driver went offline — remove the island/lock-screen activity.
  static Future<void> stop() => _invoke('stop', null);

  static Future<void> _invoke(String method, String? status) async {
    if (!AppPlatform.isIOS) return;
    try {
      await _channel.invokeMethod(method, {
        if (status != null) 'status': status,
      });
    } catch (e) {
      debugPrint('[LiveActivity] $method failed (non-fatal): $e');
    }
  }
}
