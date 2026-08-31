import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_platform.dart';
import 'api_service.dart';

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

  static bool _tokenHookInstalled = false;

  /// Receive the ActivityKit push channels from the native side and register
  /// them with the backend. Without this the server can only banner the
  /// driver; with it, dispatch can paint the offer straight onto the Dynamic
  /// Island / lock screen while the app is backgrounded or killed.
  static void installPushTokenHook() {
    if (_tokenHookInstalled || !AppPlatform.isIOS) return;
    _tokenHookInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pushToken') {
        final args = call.arguments as Map?;
        final kind = args?['kind'] as String? ?? '';
        final token = args?['token'] as String? ?? '';
        if (kind.isNotEmpty && token.isNotEmpty) {
          await ApiService.registerLiveActivityToken(kind: kind, token: token);
        } else {
          debugPrint(
              '[LiveActivity] pushToken hook dropped empty kind="$kind" '
              'token=${token.isEmpty ? '<empty>' : 'set'}');
        }
      }
      return null;
    });
    // Tell native the handler is up. The push-to-start token emits at
    // process start — seconds before Dart runs — and only re-emits on
    // rotation, so without this handshake that first token is dropped and
    // the backend can never paint an offer on the island while the app is
    // backgrounded. Native caches every emission and replays them now.
    _invoke('pushTokenHookReady', null);
  }

  /// Driver went online — put the Cruise logo in the Dynamic Island.
  static Future<void> startOnline() {
    installPushTokenHook();
    return _invoke('start', 'online');
  }

  /// Refresh the island's status line: 'online' while waiting for offers,
  /// 'on_trip' while driving someone. Also how an offer is cleared — going
  /// back to a plain status is what takes the ride off the lock screen, and
  /// a ride that can no longer be accepted must never stay there.
  static Future<void> updateStatus(String status) => _invoke('update', status);

  /// A ride offer arrived while the driver was in another app: swap the
  /// island/lock-screen card for the offer — fare, hourly rate, distance
  /// and time, over the pickup→dropoff bar.
  ///
  /// Every value arrives pre-formatted. The widget renders exactly what it
  /// is given, so the money the driver reads here is the same string the
  /// offer card inside the app shows, from the same source.
  static Future<void> showOffer({
    required String fare,
    required String perHour,
    required String miles,
    required String minutes,
  }) =>
      _invoke('offer', 'offer', extra: {
        'fare': fare,
        'perHour': perHour,
        'miles': miles,
        'minutes': minutes,
      });

  /// Driver went offline — remove the island/lock-screen activity. The
  /// activity's push channel dies with it, so the backend's copy is cleared
  /// too; otherwise dispatch keeps paying for pushes to a dead channel.
  static Future<void> stop() {
    if (AppPlatform.isIOS) {
      ApiService.registerLiveActivityToken(kind: 'activity', token: '');
    }
    return _invoke('stop', null);
  }

  // ── Rider trip activity ─────────────────────────────────────────────
  // The rider's trip on THEIR lock screen / island while the app is
  // backgrounded (Lyft-style: drop-off ETA, destination, driver
  // photo/name/rating, car sliding along the bar). Started when a driver
  // is assigned, repainted on phase changes, ended on complete/cancel.

  static Future<void> startRide({
    required String phase, // 'en_route' | 'arrived' | 'on_trip'
    required DateTime startedAt,
    required DateTime dropoffAt,
    required String dropoffAddress,
    required String driverName,
    required String driverRating,
    required String driverPhotoUrl,
    required String carImage, // 'CarSedan' | 'CarSuv' | 'CarEconomy'
  }) =>
      _invoke('startRide', null, extra: _rideArgs(
        phase: phase, startedAt: startedAt, dropoffAt: dropoffAt,
        dropoffAddress: dropoffAddress, driverName: driverName,
        driverRating: driverRating, driverPhotoUrl: driverPhotoUrl,
        carImage: carImage,
      ));

  /// Repaint the running ride activity (phase change or ETA shift). Silent
  /// no-op when nothing is running — the activity is never force-started
  /// from here, so a stale update after the trip ended cannot resurrect it.
  static Future<void> updateRide({
    required String phase,
    required DateTime startedAt,
    required DateTime dropoffAt,
    required String dropoffAddress,
    required String driverName,
    required String driverRating,
    required String driverPhotoUrl,
    required String carImage,
  }) =>
      _invoke('updateRide', null, extra: _rideArgs(
        phase: phase, startedAt: startedAt, dropoffAt: dropoffAt,
        dropoffAddress: dropoffAddress, driverName: driverName,
        driverRating: driverRating, driverPhotoUrl: driverPhotoUrl,
        carImage: carImage,
      ));

  /// Dates cross the channel as epoch SECONDS (double) — the Swift side
  /// decodes them into Date for the timer-driven bar; every text arrives
  /// pre-formatted so the lock screen and the in-app card never disagree.
  static Map<String, Object> _rideArgs({
    required String phase,
    required DateTime startedAt,
    required DateTime dropoffAt,
    required String dropoffAddress,
    required String driverName,
    required String driverRating,
    required String driverPhotoUrl,
    required String carImage,
  }) =>
      {
        'phase': phase,
        'startedAt': startedAt.millisecondsSinceEpoch / 1000,
        'dropoffAt': dropoffAt.millisecondsSinceEpoch / 1000,
        'dropoffAddress': dropoffAddress,
        'driverName': driverName,
        'driverRating': driverRating,
        'driverPhotoUrl': driverPhotoUrl,
        'carImage': carImage,
      };

  /// Trip completed or cancelled — take the ride off the lock screen. The
  /// ride activity's push channel dies with it; the backend's copy is
  /// cleared so it stops paying for pushes to a dead channel.
  static Future<void> endRide() {
    if (AppPlatform.isIOS) {
      ApiService.registerLiveActivityToken(kind: 'ride_activity', token: '');
    }
    return _invoke('endRide', null);
  }

  static Future<void> _invoke(String method, String? status,
      {Map<String, Object>? extra}) async {
    if (!AppPlatform.isIOS) return;
    try {
      await _channel.invokeMethod(method, {
        if (status != null) 'status': status,
        ...?extra,
      });
    } catch (e) {
      debugPrint('[LiveActivity] $method failed (non-fatal): $e');
    }
  }
}
