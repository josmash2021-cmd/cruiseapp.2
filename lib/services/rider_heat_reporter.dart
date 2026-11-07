import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'api_service.dart';

typedef RiderIntentSender = Future<bool> Function({
  required String step,
  required double lat,
  required double lng,
  String? address,
  double? dropoffLat,
  double? dropoffLng,
  String? dropoffAddress,
});

typedef RiderTypingSender = Future<bool> Function({required String field});

/// The rider's trip-planning steps for the drivers' heat map (owner
/// 2026-11-05: "aparece cuando … escribe un pickup address y cuando escribe
/// el dropoff y eso es en tiempo real").
///
/// The location step is not here: [RiderPresenceService] already sends the
/// live location every 60 s and the server turns it into heat. This only
/// reports the typed pickup (step 2) and the typed dropoff (step 3), both at
/// the PICKUP point — that is where the rider will be picked up. The
/// addresses the rider sees (and, at step 3, the dropoff point) ride along
/// for the panel's live "booking now" list.
///
/// A step never goes back down while the rider keeps planning; a re-send of
/// the same step at the same place within [_minGap] is dropped. While the
/// app is in front the current step is re-sent every [heartbeat] so the
/// server keeps it (it forgets after 3 min), for at most [planningWindow]
/// after the rider last did something. The beat carries the same full
/// payload as the last report.
///
/// [typing] tells the panel the rider is typing an address — at most once
/// every [typingGap] per field, nothing between keystrokes.
class RiderHeatReporter {
  RiderHeatReporter({
    RiderIntentSender? sender,
    RiderTypingSender? typingSender,
    DateTime Function()? clock,
    bool Function()? inForeground,
    this.heartbeat = const Duration(seconds: 60),
    this.planningWindow = const Duration(minutes: 15),
    this.typingGap = const Duration(seconds: 20),
  })  : _sender = sender ?? ApiService.reportTripIntent,
        _typingSender = typingSender ?? ApiService.reportTyping,
        _clock = clock ?? DateTime.now,
        _inForeground = inForeground ?? _appInForeground;

  static final RiderHeatReporter instance = RiderHeatReporter();

  static const Duration _minGap = Duration(seconds: 25);
  static const double _movedM = 30;

  final RiderIntentSender _sender;
  final RiderTypingSender _typingSender;
  final DateTime Function() _clock;
  final bool Function() _inForeground;
  final Duration heartbeat;
  final Duration planningWindow;
  final Duration typingGap;

  int _step = 0;
  double? _lat;
  double? _lng;
  String? _pickupAddress;
  double? _dropoffLat;
  double? _dropoffLng;
  String? _dropoffAddress;
  DateTime? _actedAt;
  DateTime? _sentAt;
  Timer? _beat;

  /// Last typing signal per field ('pickup' / 'dropoff').
  final Map<String, DateTime> _typedAt = {};

  /// 0 = nothing reported, 2 = pickup typed, 3 = dropoff typed.
  int get step => _step;

  /// The rider typed (or confirmed) the pickup at [lat]/[lng];
  /// [pickupAddress] is the text they see for it.
  void pickup(double lat, double lng, {String? pickupAddress}) =>
      _report(2, lat, lng, pickupAddress: pickupAddress);

  /// The rider typed the dropoff; [lat]/[lng] is the PICKUP (or the
  /// rider's current location when no pickup was typed), [pickupAddress]
  /// its text. [dropoffLat]/[dropoffLng] (both or neither) and
  /// [dropoffAddress] are the chosen dropoff.
  void dropoff(
    double lat,
    double lng, {
    String? pickupAddress,
    double? dropoffLat,
    double? dropoffLng,
    String? dropoffAddress,
  }) =>
      _report(
        3,
        lat,
        lng,
        pickupAddress: pickupAddress,
        dropoffLat: dropoffLat,
        dropoffLng: dropoffLng,
        dropoffAddress: dropoffAddress,
        withDropoff: true,
      );

  /// The rider changed the text of the pickup (`'pickup'`) or the dropoff
  /// (`'dropoff'`) search field. The first change is sent at once, then at
  /// most one per [typingGap] per field while they keep typing.
  void typing(String field, String text) {
    if (field != 'pickup' && field != 'dropoff') return;
    if (text.trim().isEmpty) return;
    final now = _clock();
    final last = _typedAt[field];
    if (last != null && now.difference(last) < typingGap) return;
    _typedAt[field] = now;
    unawaited(
        _typingSender(field: field).catchError((Object _) => false));
  }

  /// The rider picked an address or left the search page: the typing run is
  /// over, the next keystroke starts a new one.
  void typingDone() => _typedAt.clear();

  /// A driver took the ride: nothing to plan any more. No request — the
  /// server already leaves out riders whose trip has a driver.
  void reset() {
    _beat?.cancel();
    _beat = null;
    _step = 0;
    _lat = null;
    _lng = null;
    _pickupAddress = null;
    _dropoffLat = null;
    _dropoffLng = null;
    _dropoffAddress = null;
    _actedAt = null;
    _sentAt = null;
    _typedAt.clear();
  }

  void _report(
    int step,
    double lat,
    double lng, {
    String? pickupAddress,
    double? dropoffLat,
    double? dropoffLng,
    String? dropoffAddress,
    bool withDropoff = false,
  }) {
    if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return;
    final now = _clock();
    final next = math.max(step, _step);
    final moved = _lat == null || _distanceM(_lat!, _lng!, lat, lng) > _movedM;

    // The pickup text: the new one, else the old one while the pickup is
    // where it was (a moved pickup without text has none).
    final pickupText =
        _clean(pickupAddress) ?? (moved ? null : _pickupAddress);

    // The dropoff: both coordinates or neither; kept from before when a
    // call does not carry one (the step never goes back down).
    var dLat = _dropoffLat, dLng = _dropoffLng, dText = _dropoffAddress;
    if (withDropoff) {
      final validPoint = dropoffLat != null &&
          dropoffLng != null &&
          dropoffLat.isFinite &&
          dropoffLng.isFinite &&
          !(dropoffLat == 0 && dropoffLng == 0);
      if (validPoint) {
        final dropoffMoved = dLat == null ||
            _distanceM(dLat, dLng!, dropoffLat, dropoffLng) > _movedM;
        dLat = dropoffLat;
        dLng = dropoffLng;
        dText = _clean(dropoffAddress) ?? (dropoffMoved ? null : dText);
      } else {
        dText = _clean(dropoffAddress) ?? dText;
      }
    }

    final dropoffChanged = next >= 3 &&
        (dLat != _dropoffLat || dLng != _dropoffLng || dText != _dropoffAddress);
    final textChanged = pickupText != _pickupAddress;

    _actedAt = now;
    if (next == _step &&
        !moved &&
        !dropoffChanged &&
        !textChanged &&
        _sentAt != null &&
        now.difference(_sentAt!) < _minGap) {
      return;
    }
    _step = next;
    _lat = lat;
    _lng = lng;
    _pickupAddress = pickupText;
    _dropoffLat = dLat;
    _dropoffLng = dLng;
    _dropoffAddress = dText;
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
    final atDropoff = _step >= 3;
    unawaited(_sender(
      step: atDropoff ? 'dropoff' : 'pickup',
      lat: lat,
      lng: lng,
      address: _pickupAddress,
      dropoffLat: atDropoff ? _dropoffLat : null,
      dropoffLng: atDropoff ? _dropoffLng : null,
      dropoffAddress: atDropoff ? _dropoffAddress : null,
    ).catchError((Object _) => false));
  }

  /// Placeholders the pickup field shows before the reverse geocode lands.
  /// Not an address: leaving it out lets the server look the point up.
  static const Set<String> _placeholders = {
    'ubicación actual',
    'current location',
    'tu ubicación',
    'your location',
  };

  static String? _clean(String? text) {
    final t = text?.trim() ?? '';
    if (t.isEmpty || _placeholders.contains(t.toLowerCase())) return null;
    return t.length > 300 ? t.substring(0, 300) : t;
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
