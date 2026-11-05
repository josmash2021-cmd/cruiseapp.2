import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'api_service.dart';

typedef RiderIntentSender = Future<bool> Function({
  required String step,
  required double lat,
  required double lng,
});

/// The rider's trip-planning steps for the drivers' heat map (owner
/// 2026-11-05: "aparece cuando … escribe un pickup address y cuando escribe
/// el dropoff y eso es en tiempo real").
///
/// The location step is not here: [RiderPresenceService] already sends the
/// live location every 60 s and the server turns it into heat. This only
/// reports the typed pickup (step 2) and the typed dropoff (step 3), both at
/// the PICKUP point — that is where the rider will be picked up.
///
/// A step never goes back down while the rider keeps planning; a re-send of
/// the same step at the same place within [_minGap] is dropped. While the
/// app is in front the current step is re-sent every [heartbeat] so the
/// server keeps it (it forgets after 3 min), for at most [planningWindow]
/// after the rider last did something.
class RiderHeatReporter {
  RiderHeatReporter({
    RiderIntentSender? sender,
    DateTime Function()? clock,
    bool Function()? inForeground,
    this.heartbeat = const Duration(seconds: 60),
    this.planningWindow = const Duration(minutes: 15),
  })  : _sender = sender ?? ApiService.reportTripIntent,
        _clock = clock ?? DateTime.now,
        _inForeground = inForeground ?? _appInForeground;

  static final RiderHeatReporter instance = RiderHeatReporter();

  static const Duration _minGap = Duration(seconds: 25);
  static const double _movedM = 30;

  final RiderIntentSender _sender;
  final DateTime Function() _clock;
  final bool Function() _inForeground;
  final Duration heartbeat;
  final Duration planningWindow;

  int _step = 0;
  double? _lat;
  double? _lng;
  DateTime? _actedAt;
  DateTime? _sentAt;
  Timer? _beat;

  /// 0 = nothing reported, 2 = pickup typed, 3 = dropoff typed.
  int get step => _step;

  /// The rider typed (or confirmed) the pickup at [lat]/[lng].
  void pickup(double lat, double lng) => _report(2, lat, lng);

  /// The rider typed the dropoff; [lat]/[lng] is the PICKUP (or the
  /// rider's current location when no pickup was typed).
  void dropoff(double lat, double lng) => _report(3, lat, lng);

  /// A driver took the ride: nothing to plan any more. No request — the
  /// server already leaves out riders whose trip has a driver.
  void reset() {
    _beat?.cancel();
    _beat = null;
    _step = 0;
    _lat = null;
    _lng = null;
    _actedAt = null;
    _sentAt = null;
  }

  void _report(int step, double lat, double lng) {
    if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return;
    final now = _clock();
    final next = math.max(step, _step);
    final moved = _lat == null || _distanceM(_lat!, _lng!, lat, lng) > _movedM;
    _actedAt = now;
    if (next == _step &&
        !moved &&
        _sentAt != null &&
        now.difference(_sentAt!) < _minGap) {
      return;
    }
    _step = next;
    _lat = lat;
    _lng = lng;
    _send(now);
    _beat ??= Timer.periodic(heartbeat, (_) => _tick());
  }

  void _tick() {
    final acted = _actedAt;
    final now = _clock();
    if (_step < 2 || acted == null || now.difference(acted) > planningWindow) {
      reset();
      return;
    }
    // In the background the presence service has already told the server
    // the rider left — a beat from a suspended app must not bring them back.
    if (!_inForeground()) return;
    _send(now);
  }

  void _send(DateTime now) {
    final lat = _lat, lng = _lng;
    if (lat == null || lng == null || _step < 2) return;
    _sentAt = now;
    unawaited(_sender(
      step: _step >= 3 ? 'dropoff' : 'pickup',
      lat: lat,
      lng: lng,
    ).catchError((Object _) => false));
  }

  static bool _appInForeground() {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  static double _distanceM(double aLat, double aLng, double bLat, double bLng) {
    const r = 6371000.0;
    final x = (bLng - aLng) * math.pi / 180 *
        math.cos((aLat + bLat) / 2 * math.pi / 180);
    final y = (bLat - aLat) * math.pi / 180;
    return math.sqrt(x * x + y * y) * r;
  }
}
