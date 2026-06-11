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
/// (constant-velocity + gentle correction + shortest-arc bearing).
/// The dot is driven by a real vsync [Ticker].
///
/// Visual: single static gold dot with white halo — rendered once,
/// no sprite atlas, no heavy initState cost.
class GoldLocationDot {
  static const Color _gold = Color(0xFFE8C547);
  static const double _canvasSize = 160.0;
  static const double _dotR = 18.0;

  final SmoothMotion _motion = SmoothMotion();

  Uint8List? _frame;
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;
  VoidCallback? _onTick;
  TickerProvider? _vsync;
  bool _isDisposing = false;

  /// Interpolated position — use this to place the Mapbox annotation.
  double? get lat => _motion.lat;
  double? get lng => _motion.lng;

  bool get isReady => _frame != null;

  Uint8List? get currentBytes => _frame;

  /// Feed each raw GPS fix. The dot glides toward it at the measured
  /// velocity — no jumps, no stalls.
  void setTarget(double lat, double lng) => _motion.setTarget(lat, lng);

  /// Hard-reset the rendered position (e.g. resuming from background).
  void snapTo(double lat, double lng) => _motion.snapTo(lat, lng);

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

    // Outer glow (static, no pulse)
    canvas.drawCircle(
      center,
      _dotR * 1.8,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Middle halo
    canvas.drawCircle(
      center,
      _dotR * 1.3,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    // White ring
    canvas.drawCircle(
      center,
      _dotR,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Gold core
    canvas.drawCircle(
      center,
      _dotR - 1.5,
      Paint()..color = _gold.withValues(alpha: 0.9),
    );

    final img = await recorder
        .endRecording()
        .toImage(_canvasSize.toInt(), _canvasSize.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    _frame = data.buffer.asUint8List();

    _lastElapsed = Duration.zero;
    _onTick = onTick;
    _vsync = vsync;
    _ticker?.dispose();
    _ticker = vsync.createTicker((elapsed) {
      final dtSec = _lastElapsed == Duration.zero
          ? 0.0
          : (elapsed - _lastElapsed).inMicroseconds / 1e6;
      _lastElapsed = elapsed;

      final posChanged = _motion.tick(dtSec);
      if (posChanged) onTick();
    })
      ..start();
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
