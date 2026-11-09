import 'dart:math' as math;

import 'live_activity_service.dart';

/// The driver's trip on their own lock screen / Dynamic Island, as the
/// owner-approved drawing (2026-11-09,
/// https://claude.ai/artifact/DoSsRsv83hW7ULJWJgoetK §5): "Recoge a María
/// en 4 min", "Esperando a María · Espera gratis 3:12", "Deja a María en
/// 12 min".
///
/// The trip screen says WHICH leg the driver is on ([setLeg]); navigation
/// says how long it takes ([reportEtaSeconds]); without navigation the
/// screen's GPS gives a straight-line estimate ([reportPosition]). The
/// online screen re-sends the card on its clock ([push]) so a server
/// repaint (an offer cleared at accept) never sticks.
class DriverTripIsland {
  DriverTripIsland._();

  static int? _tripId;
  static String _phase = '';
  static String _riderName = '';
  static String _riderRating = '';
  static String _riderPhotoUrl = '';
  static String _address = '';
  static String _waitRate = '';
  static double? _targetLat;
  static double? _targetLng;
  static DateTime? _legStart;
  static DateTime? _legEnd;
  static DateTime? _freeWaitEnd;
  static DateTime? _navEtaAt;

  static String _lastKey = '';
  static DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The rider of the trip that ended last — "Ganaste $14.20 · Viaje con
  /// María" right after it.
  static String lastRiderName = '';

  static bool get active => _tripId != null;

  /// The wait fee after the free minutes, as the server charges it
  /// (_WAIT_POLICY_BY_TYPE in backend/routers/trips.py, same key
  /// normalisation as _vehicle_key).
  static String waitRateFor(String vehicleType) {
    final k = vehicleType.trim().toLowerCase().replaceAll(RegExp(r'[ -]'), '_');
    final rate = switch (k) {
      'premium' => 0.60,
      'suv_xl' || 'vip' || 'black' => 1.00,
      _ => 0.40,
    };
    return '\$${rate.toStringAsFixed(2)}/min';
  }

  /// The leg the driver is on. A new phase restarts the bar; [etaSeconds]
  /// (when the caller knows it) anchors the arrival until navigation or
  /// the GPS refines it.
  static void setLeg({
    required int tripId,
    required String phase, // to_pickup | waiting | to_stop | at_stop | to_dropoff
    required String riderName,
    required String riderRating,
    required String riderPhotoUrl,
    required String address,
    double? targetLat,
    double? targetLng,
    int? etaSeconds,
    DateTime? freeWaitEnd,
    String waitRate = '',
  }) {
    final now = DateTime.now();
    if (tripId != _tripId || phase != _phase) {
      _legStart = now;
      _legEnd = etaSeconds == null ? null : now.add(Duration(seconds: etaSeconds));
      _navEtaAt = null;
    }
    _tripId = tripId;
    _phase = phase;
    _riderName = riderName;
    _riderRating = riderRating;
    _riderPhotoUrl = riderPhotoUrl;
    _address = address;
    _targetLat = targetLat;
    _targetLng = targetLng;
    _freeWaitEnd = freeWaitEnd;
    _waitRate = waitRate;
    lastRiderName = riderName;
    push();
  }

  static bool get _moving =>
      _phase == 'to_pickup' || _phase == 'to_stop' || _phase == 'to_dropoff';

  /// Navigation's live remaining time on the current leg (road distance,
  /// traffic-aware steps). Only a change of 30 s or more repaints.
  static void reportEtaSeconds(int seconds) {
    if (_tripId == null || !_moving || seconds < 0) return;
    final now = DateTime.now();
    _navEtaAt = now;
    final end = now.add(Duration(seconds: seconds));
    final prev = _legEnd;
    if (prev != null && end.difference(prev).inSeconds.abs() < 30) return;
    _legEnd = end;
    push();
  }

  /// Without navigation: the straight line to the leg's end at an urban
  /// 24 mph × 1.3 road factor — the same fallback the rider's card uses.
  /// Ignored while navigation reported in the last minute.
  static void reportPosition(double lat, double lng) {
    if (_tripId == null || !_moving) return;
    final tLat = _targetLat;
    final tLng = _targetLng;
    if (tLat == null || tLng == null) return;
    final navAt = _navEtaAt;
    if (navAt != null && DateTime.now().difference(navAt).inSeconds < 60) {
      return;
    }
    final meters = _haversineM(lat, lng, tLat, tLng) * 1.3;
    final seconds = (meters / 10.7).round(); // 24 mph ≈ 10.7 m/s
    final end = DateTime.now().add(Duration(seconds: seconds));
    final prev = _legEnd;
    if (prev != null && end.difference(prev).inSeconds.abs() < 60) return;
    _legEnd = end;
    push();
  }

  /// The trip ended or was taken away — the online screen paints next.
  static void clear() {
    _tripId = null;
    _phase = '';
    _legStart = null;
    _legEnd = null;
    _freeWaitEnd = null;
    _navEtaAt = null;
    _lastKey = '';
  }

  /// Sends the card when it changed, and at least every 30 s while a trip
  /// runs ([force] always) — a repaint from the server can land on top.
  static void push({bool force = false}) {
    final id = _tripId;
    if (id == null) return;
    final key = [
      id, _phase, _riderName, _riderRating, _riderPhotoUrl, _address,
      _legEnd?.millisecondsSinceEpoch, _freeWaitEnd?.millisecondsSinceEpoch,
      _waitRate,
    ].join('|');
    final now = DateTime.now();
    if (!force &&
        key == _lastKey &&
        now.difference(_lastSentAt) < const Duration(seconds: 30)) {
      return;
    }
    _lastKey = key;
    _lastSentAt = now;
    LiveActivityService.updateDriver(
      status: 'on_trip',
      phase: _phase,
      riderName: _riderName,
      riderRating: _riderRating,
      riderPhotoUrl: _riderPhotoUrl,
      address: _address,
      legStart: _legStart,
      legEnd: _legEnd,
      freeWaitEnd: _freeWaitEnd,
      waitRate: _waitRate,
    );
  }

  static double _haversineM(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }
}
