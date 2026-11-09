import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_platform.dart';
import 'api_service.dart';
import 'notification_service.dart';

/// Set while this phone shows a trip card (iPhone Live Activity or the
/// Android trip notification); cleared when it comes down.
const _kRideCardUpKey = 'ride_card_up';

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

  /// Settings > Cruise > Live Activities — is the island even allowed to
  /// appear? When it is off, every token path silently no-ops and the
  /// driver never sees offers outside the app (prod 2026-10-02: zero LA
  /// token registrations fleet-wide, invisible until the server was
  /// queried). The online screen asks this once per shift so it can say
  /// so out loud. Non-iOS and older native builds answer true — no
  /// banner for a feature that does not exist there.
  static Future<bool> areActivitiesEnabled() async {
    if (!AppPlatform.isIOS) return true;
    try {
      final v = await _channel.invokeMethod<bool>('activitiesEnabled');
      return v ?? true;
    } catch (_) {
      return true;
    }
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
    String carLine = '', // "Toyota Camry gris" (vehicleCarLine)
    String plate = '',
  }) =>
      _invoke('startRide', null, extra: _rideArgs(
        phase: phase, startedAt: startedAt, dropoffAt: dropoffAt,
        dropoffAddress: dropoffAddress, driverName: driverName,
        driverRating: driverRating, driverPhotoUrl: driverPhotoUrl,
        carImage: carImage, carLine: carLine, plate: plate,
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
    String carLine = '',
    String plate = '',
  }) =>
      _invoke('updateRide', null, extra: _rideArgs(
        phase: phase, startedAt: startedAt, dropoffAt: dropoffAt,
        dropoffAddress: dropoffAddress, driverName: driverName,
        driverRating: driverRating, driverPhotoUrl: driverPhotoUrl,
        carImage: carImage, carLine: carLine, plate: plate,
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
    required String carLine,
    required String plate,
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
        // Lyft-style card (owner 2026-11-09): the car and its plate, what
        // the rider looks for on the street. Binaries older than this
        // ignore both keys.
        'carLine': carLine,
        'plate': plate,
      };

  /// Trip completed or cancelled — take the ride off the lock screen. The
  /// ride activity's push channel dies with it; the backend's copy is
  /// cleared so it stops paying for pushes to a dead channel.
  static Future<void> endRide() {
    if (AppPlatform.isIOS) {
      ApiService.registerLiveActivityToken(kind: 'ride_activity', token: '');
    }
    unawaited(markRideCard(false));
    return _invoke('endRide', null);
  }

  /// Notes that a trip card went up (or came down), so Inicio can take an
  /// ORPHAN down — one that outlived its trip because both end paths
  /// missed (app closed and no card token on the server) — without asking
  /// the server on every open when no card was ever shown.
  static Future<void> markRideCard(bool up) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kRideCardUpKey, up);
    } catch (_) {}
  }

  static Future<bool> rideCardMaybeUp() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(_kRideCardUpKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// A trip card that outlived its trip comes down when the app opens or
  /// comes back (owner 2026-11-09: "¿no se queda dibujada aun así termine
  /// el viaje?"). The trip screen ends it, the server ends it by push — and
  /// with the app closed and no card token on the server neither runs;
  /// iOS then keeps it up to 12 h (staleDate only greys it, it never
  /// removes it). Ended unless the server says a ride is under way; a
  /// failed read (timeout, redeploy 502) changes nothing.
  static Future<void> endOrphanRideCard() async {
    if (kIsWeb) return;
    if (!await rideCardMaybeUp()) return;
    final status = await ApiService.activeTripStatusOrNull();
    if (status == null || _kRideCardStatuses.contains(status)) return;
    debugPrint('[LiveActivity] trip card outlived its trip '
        '(status "$status") — ending');
    await endRide();
    await NotificationService.cancelTripProgress();
  }

  /// Statuses where a trip card legitimately shows (the driver assigned and
  /// coming, waiting, or the ride under way).
  static const _kRideCardStatuses = {
    'accepted', 'driver_assigned', 'driver_en_route', 'en_route',
    'en_route_to_pickup', 'driver_arriving', 'arriving', 'arrived',
    'driver_arrived', 'in_trip', 'in_progress', 'on_trip',
    // A reservation inside its last 30 min — when unsure, keep the card.
    'scheduled_active',
  };

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
