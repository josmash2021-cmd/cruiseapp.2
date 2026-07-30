import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../utils/smooth_motion.dart';

/// Animated own-location marker for Mapbox map screens.
///
/// Position smoothing is delegated to the canonical [SmoothMotion]
/// (constant-velocity + gentle correction + shortest-arc bearing).
/// The marker is driven by a real vsync [Ticker].
///
/// Two looks, one motion engine:
///
///  * default — the gold dot with a white ring. What a rider sees for
///    themselves: they are somewhere, they are not steering.
///  * [heading] — the navigation badge: black disc, gold ring, white arrow.
///    For the driver screens, where the direction the car is pointing is
///    half of what the marker has to say.
///
/// The arrow is rasterised once pointing north and turned by the map, never
/// redrawn per heading: callers set `iconRotate` on the annotation from
/// [bearing]. Re-encoding a PNG on every GPS fix is not a rotation.
class GoldLocationDot {
  GoldLocationDot({this.heading = false});

  /// Draw the direction arrow instead of the plain dot. Driver screens only.
  final bool heading;

  static const Color _gold = Color(0xFFE8C547);
  static const Color _body = Color(0xFF07070A);
  static const double _canvasSize = 160.0;
  /// Outer edge of the marker.
  static const double _dotR = 20.0;
  /// The plain dot is smaller than the badge — it has no arrow to hold.
  static const double _plainDotR = 18.0;

  final SmoothMotion _motion = SmoothMotion();

  Uint8List? _frame;
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;
  VoidCallback? _onTick;
  TickerProvider? _vsync;
  bool _isDisposing = false;

  // Throttle annotation redraws to ~30 fps. Mapbox point annotations don't
  // benefit from 60 fps updates and the extra platform-channel traffic can
  // cause micro-stutter on mid-range devices.
  static const int _minTickIntervalMs = 33;
  DateTime? _lastTickAt;

  /// Interpolated position — use this to place the Mapbox annotation.
  double? get lat => _motion.lat;
  double? get lng => _motion.lng;

  /// Smoothed heading in degrees (0 = north). Feed this straight into the
  /// annotation's `iconRotate` — the bitmap is drawn pointing north.
  double get bearing => _motion.bearing;

  bool get isReady => _frame != null;

  Uint8List? get currentBytes => _frame;

  /// Feed each raw GPS fix. The dot glides toward it at the measured
  /// velocity — no jumps, no stalls.
  ///
  /// [bearing] is optional because not every fix carries one: geolocator
  /// reports heading as -1 when the device cannot determine it (stationary,
  /// or no compass), and passing that through would swing the arrow to north
  /// every time the driver stops. Callers should drop invalid headings
  /// rather than forward them.
  void setTarget(double lat, double lng, {double? bearing}) =>
      _motion.setTarget(lat, lng, bearing: bearing);

  /// Hard-reset the rendered position (e.g. resuming from background).
  void snapTo(double lat, double lng, {double? bearing}) =>
      _motion.snapTo(lat, lng, bearing: bearing);

  /// Build the dot image once, then start the vsync ticker.
  ///
  /// [vsync] must stay alive for the lifetime of the dot (usually the
  /// hosting [State] with `TickerProviderStateMixin`). [onTick] is called
  /// whenever the position changes and the annotation needs a redraw.
  Future<void> build(TickerProvider vsync, VoidCallback onTick) async {
    // Render a single static frame — no sprite atlas, no 90-frame loop.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, _canvasSize, _canvasSize),
    );
    const center = Offset(_canvasSize / 2, _canvasSize / 2);

    if (heading) {
      _paintHeadingBadge(canvas, center);
    } else {
      _paintPlainDot(canvas, center);
    }

    // Rasterising can fail (GPU context lost while backgrounding, OOM on
    // low-end devices). Left unguarded it escapes as an unhandled async
    // error AND leaves _frame null forever, so the dot never draws again
    // — callers see currentBytes == null and silently give up.
    try {
      final img = await recorder
          .endRecording()
          .toImage(_canvasSize.toInt(), _canvasSize.toInt());
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (data == null || _isDisposing) return;
      _frame = data.buffer.asUint8List();
    } catch (e) {
      debugPrint('[GoldLocationDot] frame render failed: $e');
      return; // isReady stays false; the caller may build() again later
    }

    _lastElapsed = Duration.zero;
    _onTick = onTick;
    _vsync = vsync;
    _ticker?.dispose();
    try {
      _ticker = vsync.createTicker((elapsed) {
        final dtSec = _lastElapsed == Duration.zero
            ? 0.0
            : (elapsed - _lastElapsed).inMicroseconds / 1e6;
        _lastElapsed = elapsed;

        final posChanged = _motion.tick(dtSec);
        if (!posChanged) return;

        final now = DateTime.now();
        if (_lastTickAt != null &&
            now.difference(_lastTickAt!).inMilliseconds < _minTickIntervalMs) {
          return;
        }
        _lastTickAt = now;
        onTick();
      })
        ..start();
    } catch (_) {
      // TickerProvider was disposed while we were awaiting the image.
      // Leave the dot ready for the next build call.
      _ticker = null;
      _onTick = null;
      _vsync = null;
    }
  }

  /// The classic marker: gold core, white ring, soft white halo.
  static void _paintPlainDot(Canvas canvas, Offset center) {
    canvas.drawCircle(
      center,
      _plainDotR * 1.8,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(
      center,
      _plainDotR * 1.3,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(
      center,
      _plainDotR,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      center,
      _plainDotR - 1.5,
      Paint()..color = _gold.withValues(alpha: 0.9),
    );
  }

  /// The driver badge: black disc, gold ring, white arrow pointing north.
  static void _paintHeadingBadge(Canvas canvas, Offset center) {
    // Gold halo — the only thing holding the badge off a dark map. Kept
    // faint: this sits under the driver's own car at all times.
    canvas.drawCircle(
      center,
      _dotR * 1.7,
      Paint()
        ..color = _gold.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );

    // Black body.
    canvas.drawCircle(center, _dotR, Paint()..color = _body);

    // Gold ring around it.
    canvas.drawCircle(
      center,
      _dotR - 1.75,
      Paint()
        ..color = _gold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5,
    );

    // White arrow, drawn pointing north — the map turns it.
    //
    // The notch in the base is what makes it read as a direction arrow
    // rather than a triangle; it is the shape every navigation app uses,
    // and the one the driver already knows from Google Maps.
    const tipY = -11.5;      // apex, relative to centre
    const baseY = 9.5;       // outer corners
    const notchY = 4.0;      // centre of the base, pulled up
    const halfW = 8.6;
    final arrow = Path()
      ..moveTo(center.dx, center.dy + tipY)
      ..lineTo(center.dx + halfW, center.dy + baseY)
      ..lineTo(center.dx, center.dy + notchY)
      ..lineTo(center.dx - halfW, center.dy + baseY)
      ..close();

    // Shadow under the arrow so it survives against the gold ring.
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawPath(arrow, Paint()..color = Colors.white);
  }

  /// Restart the ticker if it was stopped (e.g. after app resume).
  /// Safe to call multiple times. No-op if [dispose] has already been called.
  void ensureRunning() {
    if (_isDisposing) return;
    if (_ticker == null || _onTick == null || _vsync == null) return;
    if (!_ticker!.isActive) {
      _lastElapsed = Duration.zero;
      _ticker!.start();
    }
  }

  void dispose() {
    _isDisposing = true;
    _ticker?.dispose();
    _ticker = null;
    _onTick = null;
    _vsync = null;
  }
}
