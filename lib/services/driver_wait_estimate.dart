import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_service.dart';

/// How long the rider is likely to wait, and whether anyone can come at all.
///
/// One fetch per pickup point, cached, so tapping between vehicle types is
/// instant — the answer does not change because the rider picked a different
/// car, and making them watch a spinner on every tap would turn a decision
/// into a wait.
@immutable
class WaitEstimate {
  const WaitEstimate({required this.driverCount, required this.minMinutes, required this.maxMinutes});

  /// Drivers online inside [DriverWaitEstimate.radiusMiles] of the pickup.
  final int driverCount;
  final int minMinutes;
  final int maxMinutes;

  /// Nobody within range. The ride cannot be requested.
  bool get hasDrivers => driverCount > 0;
}

/// Turns "how many drivers are near" into "how long until one arrives".
class DriverWaitEstimate {
  DriverWaitEstimate._();

  /// The catchment the rider is told about. 20 miles, per product.
  static const double radiusMiles = 20.0;
  static const double _milesToKm = 1.60934;

  /// The floor and ceiling of the range shown. Deliberately a range and not
  /// a single number: this is derived from how many drivers are online, not
  /// from anyone actually being dispatched, so a precise "7 min" would be a
  /// promise the app is in no position to make.
  static const int _bestCase = 5;
  static const int _worstCase = 20;

  static final Map<String, WaitEstimate> _cache = <String, WaitEstimate>{};
  static final Map<String, Future<WaitEstimate>> _inFlight =
      <String, Future<WaitEstimate>>{};

  /// Round to ~1 km so a rider nudging the pin does not re-fetch.
  static String _key(double lat, double lng) =>
      '${lat.toStringAsFixed(2)},${lng.toStringAsFixed(2)}';

  /// The answer if we already have it, for a first paint with no gap.
  static WaitEstimate? cached(double lat, double lng) => _cache[_key(lat, lng)];

  static Future<WaitEstimate> fetch({
    required double lat,
    required double lng,
  }) {
    final key = _key(lat, lng);
    final hit = _cache[key];
    if (hit != null) return Future<WaitEstimate>.value(hit);
    // Share one request between simultaneous callers — the card and whatever
    // else asks on the same frame must not become two round trips.
    final pending = _inFlight[key];
    if (pending != null) return pending;

    final future = _load(lat, lng).then((e) {
      _cache[key] = e;
      _inFlight.remove(key);
      return e;
    }).catchError((Object err) {
      _inFlight.remove(key);
      // Unknown is not the same as none. Failing to reach the server must
      // not tell the rider there are no drivers and disable their ride —
      // report the widest honest range and let them try.
      debugPrint('[WaitEstimate] lookup failed: $err');
      return const WaitEstimate(
        driverCount: -1,
        minMinutes: _bestCase,
        maxMinutes: _worstCase,
      );
    });
    _inFlight[key] = future;
    return future;
  }

  static Future<WaitEstimate> _load(double lat, double lng) async {
    final count = await ApiService.getNearbyDriversCount(
      lat: lat,
      lng: lng,
      radiusKm: radiusMiles * _milesToKm,
    );
    return WaitEstimate(
      driverCount: count,
      minMinutes: _bestCase,
      maxMinutes: _worstCase,
    );
  }

  /// Drop everything — used when the rider changes pickup entirely.
  static void clear() {
    _cache.clear();
    _inFlight.clear();
  }
}
