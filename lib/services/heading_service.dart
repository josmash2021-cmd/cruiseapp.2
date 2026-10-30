import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../utils/fix_kinematics.dart';

/// Which way the driver's arrow should point, from whichever sensor can
/// currently answer.
///
/// There are two different questions hiding behind one word. *Course* is the
/// direction the car is travelling, which the GPS derives from consecutive
/// fixes. *Heading* is the direction the phone is facing, which the compass
/// reads from the magnetometer. On a moving car they agree. On a parked one
/// only the compass has anything to say — the GPS reports −1, because a car
/// that is not going anywhere is not going anywhere in a particular
/// direction.
///
/// The app used the GPS alone, and gated it further on speed (below 2.5 km/h
/// the reading was thrown away, because a course computed from GPS noise at
/// walking pace spins). The result was an arrow that could not turn while the
/// driver was stopped — which is most of the time they are looking at it.
///
/// So: compass while stopped, course while driving, with a dead band between
/// the two so a car crawling in traffic does not flip back and forth every
/// few seconds.
class HeadingService {
  HeadingService({Stream<double>? compassReadings, DateTime Function()? now})
      : _compassReadings = compassReadings,
        _now = now ?? DateTime.now;

  final Stream<double>? _compassReadings;
  final DateTime Function() _now;

  /// Above this ground speed the GPS course is trusted. ~11 km/h — fast
  /// enough that consecutive fixes describe a real direction of travel.
  static const double _useCourseAboveMps = 3.0;

  /// Below this, back to the compass. The gap between the two is the
  /// hysteresis: without it a car in stop-start traffic would cross a single
  /// threshold repeatedly and the arrow would swap sources every few seconds,
  /// which looks like the arrow twitching for no reason.
  static const double _useCompassBelowMps = 1.5;

  /// Drops only sub-perceptual duplicates; slow real turns must keep flowing.
  static const double _compassDeadBandDeg = 0.02;

  /// Circular EMA applied to the compass branch (user report 2026-09-27:
  /// "la flecha gira paso a paso y a veces se mueve hasta estabilizarse").
  /// Raw magnetometer headings arrive in steps of several degrees, and each
  /// step used to be forwarded raw — the arrow hopped and the heading-up
  /// camera swung with it. At the sensor's ~20 Hz an alpha of 0.08 is a
  /// ~0.4 s time constant: sensor steps arrive as one smooth sweep, while a
  /// real turn still lands fast enough to read as instant. Applied to the
  /// compass ONLY — the GPS course while driving belongs to SmoothMotion's
  /// turn-rate channel (pre-lagging it there poisoned that measurement,
  /// 2026-09-25).
  static const double _compassAlpha = 0.08;
  double? _compassEma;

  /// Fastest we will forward compass readings. Android delivers them at up to
  /// 60 Hz; the marker turns at a fixed rate per second regardless, so
  /// anything past ~20 Hz is work nobody can see.
  static const Duration _minInterval = Duration(milliseconds: 50);

  final _controller = StreamController<double>.broadcast();

  StreamSubscription<dynamic>? _compassSub;
  double? _lastEmitted;
  DateTime? _lastEmitAt;

  /// Latest compass reading, whether or not it was forwarded.
  double? _compass;

  /// Latest GPS course, and whether the car was moving fast enough to mean it.
  double? _course;
  bool _movingFast = false;

  /// The most recent heading handed out, or null before the first reading.
  double? get value => _lastEmitted;

  /// True while the GPS course is winning — the car is driving.
  bool get usingCourse => _movingFast && _course != null;

  /// Headings in degrees clockwise from north.
  Stream<double> get stream => _controller.stream;

  /// Begin listening. Safe to call more than once.
  void start() {
    if (_compassSub != null) return;
    // flutter_compass is Android and iOS only. On web the platform channel is
    // not registered and the first listen throws MissingPluginException —
    // which, coming from a stream, arrives as an unhandled async error rather
    // than something the caller can try/catch.
    if (kIsWeb) return;
    final injected = _compassReadings;
    if (injected != null) {
      _compassSub = injected.listen(
        _onCompassHeading,
        onError: (Object e) => debugPrint('[Heading] compass error: $e'),
        cancelOnError: false,
      );
      return;
    }
    try {
      final events = FlutterCompass.events;
      if (events == null) {
        debugPrint('[Heading] no compass on this device');
        return;
      }
      _compassSub = events.listen(
        _onCompass,
        onError: (Object e) => debugPrint('[Heading] compass error: $e'),
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[Heading] compass unavailable: $e');
    }
  }

  void _onCompass(CompassEvent e) => _onCompassHeading(e.heading);

  void _onCompassHeading(double? h) {
    // Null means the sensor has nothing — uncalibrated, or absent. iOS also
    // reports negative values while the heading is invalid.
    if (h == null || h.isNaN || h.isInfinite || h < 0) return;
    _compass = h % 360;
    // Circular EMA over the shortest arc (359° → 1° moves +2°, not −358°).
    // Tracks in the background while the GPS course owns the arrow, so the
    // switch back to compass opens on a settled value, not a stale one.
    final ema = _compassEma;
    if (ema == null) {
      _compassEma = _compass;
    } else {
      var delta = (_compass! - ema) % 360;
      if (delta > 180) delta -= 360;
      if (delta < -180) delta += 360;
      _compassEma = (ema + delta * _compassAlpha) % 360;
    }
    if (!usingCourse) {
      _emit(_compassEma!, deadBand: _compassDeadBandDeg);
      return;
    }
    _turnAssist();
  }

  /// Instant turns while driving (owner request 2026-10-29: "como Google").
  /// The GPS course updates about once a second, so the arrow used to start
  /// a turn up to a second late. The phone's heading sensor is fused with
  /// the gyroscope: its ABSOLUTE value is wrong inside a car (metal, mount),
  /// but how much it CHANGES is the car turning. Between fixes the arrow
  /// shows course + that change; the next fix re-anchors on the real
  /// course. Bounded to ±[_turnAssistMaxDeg] and [_turnAssistWindow] after
  /// the fix, so a phone moved in the hand can never spin the arrow.
  static const Duration _turnAssistWindow = Duration(milliseconds: 1600);
  static const double _turnAssistMaxDeg = 60;
  double? _compassAtCourse;
  DateTime? _courseAt;

  void _turnAssist() {
    final course = _course, at = _courseAt, base = _compassAtCourse;
    final now = _compass;
    if (course == null || at == null || base == null || now == null) return;
    if (_now().difference(at) > _turnAssistWindow) return;
    var delta = (now - base) % 360;
    if (delta > 180) delta -= 360;
    if (delta.abs() < 1.0) return; // sensor noise, not a turn
    delta = delta.clamp(-_turnAssistMaxDeg, _turnAssistMaxDeg).toDouble();
    _emit((course + delta + 360) % 360, deadBand: 0.5);
  }

  /// Feed every GPS fix. Decides which source is in charge from this point on.
  void onFix(Position p) {
    // Measured values only (2026-10-29): an Android fix without Doppler
    // reads speed 0 / heading 0 — "parked, facing north" while driving —
    // which handed the arrow to the in-car compass. Missing readings fall
    // back to what consecutive fixes show (distance / time, bearing).
    final derived = _deriveFromTrack(p);
    final double? speed = measuredSpeedMps(p) ?? derived?.$1;
    final double? course = measuredCourseDeg(p) ?? derived?.$2;
    final courseOk = course != null;

    // No compass reading — either none has arrived yet, or this device has
    // nothing to give: the browser, a tablet, a dead magnetometer. Then
    // there is nothing to choose between and the old rule is the only rule:
    // take the course whenever the car is moving faster than a walk, and
    // otherwise leave the arrow pointing where it was.
    //
    // The gate stays at 0.7 m/s here rather than dropping through to the
    // 3.0 below. Falling through would have made a phone with no compass
    // strictly worse than before this service existed.
    if (_compass == null) {
      if (courseOk && speed != null && speed >= 0.7) _emit(course % 360);
      return;
    }

    if (speed != null) {
      // Hysteresis: two thresholds, and between them whatever was already
      // chosen stays chosen.
      if (speed >= _useCourseAboveMps) {
        _movingFast = true;
      } else if (speed < _useCompassBelowMps) {
        _movingFast = false;
      }
    }

    _course = courseOk ? course % 360 : null;

    if (usingCourse) {
      _compassAtCourse = _compass;
      _courseAt = _now();
      _emit(_course!);
    } else if (_compass != null) {
      // Dropping back to the compass at a standstill: send its current
      // reading straight away rather than waiting for the sensor's next
      // event, so the arrow does not hold the last driving course.
      _emit(_compassEma ?? _compass!, deadBand: _compassDeadBandDeg);
    }
  }

  double? _trackLat;
  double? _trackLng;
  DateTime? _trackAt;

  /// (speed m/s, course deg) from the previous fix to [p], when the step is
  /// long enough to mean something (>= 6 m and >= half the fix's own error)
  /// and the spacing is a normal fix interval. Null otherwise.
  (double, double?)? _deriveFromTrack(Position p) {
    final prevLat = _trackLat, prevLng = _trackLng, prevAt = _trackAt;
    final at = p.timestamp;
    final acc = p.accuracy.isFinite && p.accuracy > 0 ? p.accuracy : 10.0;
    if (acc > 65) return null; // too vague to anchor the next step on
    _trackLat = p.latitude;
    _trackLng = p.longitude;
    _trackAt = at;
    if (prevLat == null || prevLng == null || prevAt == null) return null;
    final dt = at.difference(prevAt).inMilliseconds / 1000.0;
    if (dt < 0.3 || dt > 6.0) return null;
    final dist =
        Geolocator.distanceBetween(prevLat, prevLng, p.latitude, p.longitude);
    final speed = dist / dt;
    if (dist < 6.0 || dist < acc * 0.5) {
      return (speed < 1.0 ? 0.0 : speed, null);
    }
    final course =
        Geolocator.bearingBetween(prevLat, prevLng, p.latitude, p.longitude);
    return (speed, (course + 360) % 360);
  }

  void _emit(double heading, {double deadBand = 0}) {
    if (_controller.isClosed) return;

    final now = _now();
    if (_lastEmitAt != null && now.difference(_lastEmitAt!) < _minInterval) {
      return;
    }

    final last = _lastEmitted;
    if (last != null && deadBand > 0) {
      double gap = (heading - last).abs();
      if (gap > 180) gap = 360 - gap; // shortest arc, so 359° → 1° is 2°
      if (gap < deadBand) return;
    }

    _lastEmitted = heading;
    _lastEmitAt = now;
    _controller.add(heading);
  }

  /// Release the sensor without ending the stream.
  ///
  /// For backgrounding. A magnetometer left running behind a locked screen
  /// draws power to answer a question nobody is looking at, and this screen
  /// already drops its marker on pause. [start] picks it up again; the
  /// stream and its listeners survive, so callers do not have to re-wire.
  void stop() {
    _compassSub?.cancel();
    _compassSub = null;
  }

  void dispose() {
    stop();
    if (!_controller.isClosed) _controller.close();
  }
}
