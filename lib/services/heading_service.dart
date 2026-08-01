import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

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
  HeadingService();

  /// Above this ground speed the GPS course is trusted. ~11 km/h — fast
  /// enough that consecutive fixes describe a real direction of travel.
  static const double _useCourseAboveMps = 3.0;

  /// Below this, back to the compass. The gap between the two is the
  /// hysteresis: without it a car in stop-start traffic would cross a single
  /// threshold repeatedly and the arrow would swap sources every few seconds,
  /// which looks like the arrow twitching for no reason.
  static const double _useCompassBelowMps = 1.5;

  /// Compass readings closer together than this are dropped.
  ///
  /// A magnetometer at rest still wanders a degree or so, and every reading
  /// that gets through is a redraw. Half a degree is under what anyone can
  /// see on a 32-point arrow and it removes most of the traffic.
  static const double _compassDeadBandDeg = 0.5;

  /// Fastest we will forward compass readings. Android delivers them at up to
  /// 60 Hz; the marker turns at a fixed rate per second regardless, so
  /// anything past ~20 Hz is work nobody can see.
  static const Duration _minInterval = Duration(milliseconds: 50);

  final _controller = StreamController<double>.broadcast();

  StreamSubscription<CompassEvent>? _compassSub;
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

  void _onCompass(CompassEvent e) {
    final h = e.heading;
    // Null means the sensor has nothing — uncalibrated, or absent. iOS also
    // reports negative values while the heading is invalid.
    if (h == null || h.isNaN || h.isInfinite || h < 0) return;
    _compass = h % 360;
    if (!usingCourse) _emit(_compass!, deadBand: _compassDeadBandDeg);
  }

  /// Feed every GPS fix. Decides which source is in charge from this point on.
  void onFix(Position p) {
    final speed = p.speed;
    final course = p.heading;
    final courseOk = course.isFinite && course >= 0;

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
      if (courseOk && speed.isFinite && speed >= 0.7) _emit(course % 360);
      return;
    }

    if (speed.isFinite && speed >= 0) {
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
      _emit(_course!);
    } else if (_compass != null) {
      // Dropping back to the compass at a standstill: send its current
      // reading straight away rather than waiting for the sensor's next
      // event, so the arrow does not hold the last driving course.
      _emit(_compass!, deadBand: _compassDeadBandDeg);
    }
  }

  void _emit(double heading, {double deadBand = 0}) {
    if (_controller.isClosed) return;

    final now = DateTime.now();
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
