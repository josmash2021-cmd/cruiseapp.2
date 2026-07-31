import 'dart:async';
import 'dart:math' as math;

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
  const WaitEstimate({
    required this.driverCount,
    required this.minMinutes,
    required this.maxMinutes,
    this.nearestMiles,
  });

  /// Drivers online inside [DriverWaitEstimate.radiusMiles] of the pickup.
  final int driverCount;
  final int minMinutes;
  final int maxMinutes;

  /// How far the closest of them actually is, when it could be worked out.
  ///
  /// Null means the range is the old flat guess: either the lookup failed, or
  /// the server sent drivers without usable coordinates.
  final double? nearestMiles;

  /// Nobody within range. The ride cannot be requested.
  bool get hasDrivers => driverCount > 0;
}

/// Turns "how many drivers are near" into "how long until one arrives".
class DriverWaitEstimate {
  DriverWaitEstimate._();

  /// The catchment the rider is told about. 15 miles, per product.
  static const double radiusMiles = 15.0;
  static const double _milesToKm = 1.60934;

  /// The fallback range, used only when no distance can be worked out —
  /// the lookup failed, or drivers came back without coordinates.
  static const int _bestCase = 5;
  static const int _worstCase = 20;

  /// City driving, not highway. Turning the straight-line distance into a
  /// drive needs both of these: streets are not diagonals, so the crow's
  /// distance is multiplied before it is divided by a speed.
  static const double _avgSpeedMph = 22.0;
  static const double _roadFactor = 1.3;

  /// The beat between the request landing and the car actually moving.
  static const double _acceptMinutes = 1.5;

  /// The widest the printed range is allowed to get.
  static const int _maxSpreadMinutes = 15;

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
    final drivers = await ApiService.getNearbyDrivers(
      lat: lat,
      lng: lng,
      radiusKm: radiusMiles * _milesToKm,
    );
    if (drivers.isEmpty) {
      return const WaitEstimate(
        driverCount: 0,
        minMinutes: _bestCase,
        maxMinutes: _worstCase,
      );
    }

    final nearest = _nearestMiles(drivers, lat, lng);
    if (nearest == null) {
      // Drivers are there but none of them said where. Count is still real.
      return WaitEstimate(
        driverCount: drivers.length,
        minMinutes: _bestCase,
        maxMinutes: _worstCase,
      );
    }

    final (lo, hi) = _minutesFor(nearest);
    return WaitEstimate(
      driverCount: drivers.length,
      minMinutes: lo,
      maxMinutes: hi,
      nearestMiles: nearest,
    );
  }

  /// Distance to the closest driver, in miles.
  ///
  /// `distance_km` is preferred where the server sent it, because that came
  /// from Redis geo and cost nothing. The SQL fallback path does not compute
  /// it, so the coordinates are the fallback — which every entry has.
  static double? _nearestMiles(
    List<Map<String, dynamic>> drivers,
    double lat,
    double lng,
  ) {
    double? best;
    for (final d in drivers) {
      double? miles;
      final km = d['distance_km'];
      if (km is num && km >= 0) {
        miles = km / _milesToKm;
      } else {
        final dLat = d['lat'], dLng = d['lng'];
        if (dLat is num && dLng is num) {
          miles = _haversineMiles(lat, lng, dLat.toDouble(), dLng.toDouble());
        }
      }
      if (miles == null || miles.isNaN || miles.isInfinite) continue;
      if (best == null || miles < best) best = miles;
    }
    return best;
  }

  /// The closest driver's distance, turned into a wait.
  ///
  /// Still a range, and still honest about what it is. The distance is real
  /// now, but three things after it are not knowable from here: whether that
  /// particular driver accepts, how the lights fall, and that they are
  /// driving roads rather than the straight line this measures. So the drive
  /// time is padded on both sides instead of being printed as one number.
  ///
  /// [_avgSpeedMph] is city driving, not a highway figure, and the straight
  /// line is multiplied by [_roadFactor] because streets are not diagonals.
  /// [_acceptMinutes] covers the beat between the request landing and the car
  /// actually moving.
  static (int, int) _minutesFor(double miles) {
    final road = miles * _roadFactor;
    final drive = (road / _avgSpeedMph) * 60.0 + _acceptMinutes;
    final lo = (drive * 0.85).round();
    // Never below two minutes, and never a range so tight it reads as a
    // promise — a driver two streets away is still "2-4 min", not "2 min".
    final loC = lo < 2 ? 2 : lo;

    // Widened proportionally, but capped. A percentage on its own is fine up
    // close and useless far out: at fifteen miles it produced "44-74 min", a
    // thirty-minute window, which answers nothing. Past a point the extra
    // uncertainty is not worth printing.
    var hi = (drive * 1.25).round();
    if (hi > loC + _maxSpreadMinutes) hi = loC + _maxSpreadMinutes;
    if (hi < loC + 2) hi = loC + 2;
    return (loC, hi);
  }

  static double _haversineMiles(
      double lat1, double lon1, double lat2, double lon2) {
    const rMiles = 3958.8;
    double rad(double d) => d * math.pi / 180.0;
    final dLat = rad(lat2 - lat1);
    final dLon = rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(lat1)) *
            math.cos(rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return rMiles * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// Drop everything — used when the rider changes pickup entirely.
  static void clear() {
    _cache.clear();
    _inFlight.clear();
  }
}
