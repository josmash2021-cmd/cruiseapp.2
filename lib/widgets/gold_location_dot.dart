import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../utils/smooth_motion.dart';

/// Animated gold location dot for Mapbox map screens.
///
/// Position smoothing is delegated to the canonical [SmoothMotion]
/// (constant-velocity + gentle correction + shortest-arc bearing) — the same
/// smoother the driver car marker uses, so both feel identical. The dot is
/// driven by a real vsync [Ticker] (pass a [TickerProvider] to [build])
/// instead of a wall-clock Timer, so movement stays in lockstep with the
/// map's repaint cadence at 60/90/120 Hz.
///
/// Visual: 3-layer pulsing glow — outer expanding ring, static inner halo,
/// solid core with subtle brightness pulse. 3 s sin-based heartbeat.
class GoldLocationDot {
  static const Color _gold = Color(0xFFE8C547);
  // 90 frames × 33 ms ≈ 3 000 ms (3 s) per full pulse cycle.
  static const int _frameCount = 90;
  static const double _canvasSize = 160.0;
  static const double _dotR = 18.0;

  final SmoothMotion _motion = SmoothMotion();

  List<Uint8List> _frames = [];
  int _frame = 0;
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;
  double _frameAccumSec = 0;

  /// Interpolated position — use this to place the Mapbox annotation.
  double? get lat => _motion.lat;
  double? get lng => _motion.lng;

  bool get isReady => _frames.isNotEmpty;

  Uint8List? get currentBytes => _frames.isEmpty ? null : _frames[_frame];

  /// Feed each raw GPS fix. The dot glides toward it at the measured
  /// velocity — no jumps, no stalls.
  void setTarget(double lat, double lng) => _motion.setTarget(lat, lng);

  /// Hard-reset the rendered position (e.g. resuming from background).
  void snapTo(double lat, double lng) => _motion.snapTo(lat, lng);

  /// Build the pulse sprite atlas, then start the vsync ticker.
  ///
  /// [vsync] must stay alive for the lifetime of the dot (usually the
  /// hosting [State] with `TickerProviderStateMixin`). [onTick] is called
  /// whenever the position or pulse frame changes and the annotation
  /// needs a redraw.
  Future<void> build(TickerProvider vsync, VoidCallback onTick) async {
    final frames = <Uint8List>[];

    for (int i = 0; i < _frameCount; i++) {
      final t = i / _frameCount;
      final pulse = (math.sin(t * 2 * math.pi) + 1) / 2;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, _canvasSize, _canvasSize),
      );
      const center = Offset(_canvasSize / 2, _canvasSize / 2);

      final outerR = _dotR * (1.0 + 0.8 * pulse);
      final outerAlpha = 0.4 * (1.0 - pulse);
      canvas.drawCircle(
        center,
        outerR,
        Paint()
          ..color = Colors.white.withValues(alpha: outerAlpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );

      canvas.drawCircle(
        center,
        _dotR * 1.3,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.15)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );

      canvas.drawCircle(
        center,
        _dotR,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );

      final dotAlpha = 0.85 + 0.15 * (1.0 - pulse);
      canvas.drawCircle(
        center,
        _dotR - 1.5,
        Paint()..color = _gold.withValues(alpha: dotAlpha),
      );

      final img = await recorder
          .endRecording()
          .toImage(_canvasSize.toInt(), _canvasSize.toInt());
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      frames.add(data.buffer.asUint8List());
    }

    if (frames.length != _frameCount) return;
    _frames = frames;

    _lastElapsed = Duration.zero;
    _frameAccumSec = 0;
    _ticker?.dispose();
    _ticker = vsync.createTicker((elapsed) {
      final dtSec = _lastElapsed == Duration.zero
          ? 0.0
          : (elapsed - _lastElapsed).inMicroseconds / 1e6;
      _lastElapsed = elapsed;

      final posChanged = _motion.tick(dtSec);

      // Advance the pulse sprite every ~33 ms (≈30 fps visual) regardless
      // of display refresh rate — keeps the heartbeat constant.
      _frameAccumSec += dtSec;
      bool frameChanged = false;
      while (_frameAccumSec >= 0.033) {
        _frameAccumSec -= 0.033;
        _frame = (_frame + 1) % _frames.length;
        frameChanged = true;
      }

      if (posChanged || frameChanged) onTick();
    })
      ..start();
  }

  void dispose() {
    _ticker?.dispose();
    _ticker = null;
  }
}
