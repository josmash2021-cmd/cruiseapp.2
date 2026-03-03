import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'bearing_utils.dart';

/// 60 fps position + bearing interpolator.
///
/// Usage:
///   final m = SmoothMotion(onTick: (pos, bearing) => setState((){}));
///   m.start(this);           // call once
///   m.pushTarget(pos, brng); // on each GPS / snap update
///   m.dispose();
class SmoothMotion {
  SmoothMotion({
    required this.onTick,
    this.lerpFactor = 0.14,
    this.bearingMaxDegPerSec = 180,
    this.enablePrediction = true,
  });

  final void Function(LatLng position, double bearing) onTick;
  final double lerpFactor;
  final double bearingMaxDegPerSec;
  final bool enablePrediction;

  Ticker? _ticker;
  LatLng _current = const LatLng(0, 0);
  double _currentBearing = 0;
  LatLng _target = const LatLng(0, 0);
  double _targetBearing = 0;
  bool _hasInitial = false;

  // Velocity estimation for dead-reckoning
  LatLng? _prevTarget;
  DateTime? _prevTargetTime;
  double _velLat = 0;
  double _velLng = 0;
  DateTime? _lastFrameTime;
  static const int _maxPredMs = 1500;

  LatLng get position => _current;
  double get bearing => _currentBearing;

  double get estimatedSpeedMps {
    final vLat = _velLat * 111320;
    final vLng = _velLng * 111320 * math.cos(_current.latitude * math.pi / 180);
    return math.sqrt(vLat * vLat + vLng * vLng);
  }

  void start(TickerProvider vsync) {
    _ticker?.dispose();
    _ticker = vsync.createTicker(_onFrame)..start();
    _lastFrameTime = DateTime.now();
  }

  /// Push a new snapped target.
  /// [bearing] MUST be route-tangent (from SnapResult.bearingDeg), not raw GPS.
  void pushTarget(LatLng position, [double? bearing]) {
    if (!_hasInitial) {
      _current = position; _target = position;
      _currentBearing = bearing ?? 0; _targetBearing = _currentBearing;
      _hasInitial = true;
      _prevTarget = position; _prevTargetTime = DateTime.now();
      return;
    }
    final now = DateTime.now();
    if (_prevTarget != null && _prevTargetTime != null) {
      final dtSec = now.difference(_prevTargetTime!).inMilliseconds / 1000.0;
      if (dtSec > 0.05) {
        final nLat = (position.latitude - _prevTarget!.latitude) / dtSec;
        final nLng = (position.longitude - _prevTarget!.longitude) / dtSec;
        _velLat = _velLat * 0.55 + nLat * 0.45;
        _velLng = _velLng * 0.55 + nLng * 0.45;
      }
    }
    _prevTarget = position; _prevTargetTime = now;
    _target = position;
    if (bearing != null) _targetBearing = bearing;
  }

  void teleport(LatLng position, double bearing) {
    _current = position; _target = position;
    _currentBearing = bearing; _targetBearing = bearing;
    _hasInitial = true; _velLat = 0; _velLng = 0;
    _prevTarget = position; _prevTargetTime = DateTime.now();
  }

  void dispose() { _ticker?.stop(); _ticker?.dispose(); _ticker = null; }

  void _onFrame(Duration _) {
    if (!_hasInitial) return;
    final now = DateTime.now();
    final dtMs = (_lastFrameTime != null
        ? now.difference(_lastFrameTime!).inMilliseconds : 16).clamp(1, 100);
    _lastFrameTime = now;

    // Frame-rate-independent lerp
    final frames = dtMs / 16.667;
    final posLerp = 1.0 - math.pow(1.0 - lerpFactor, frames);

    // Dead-reckoning prediction on stale GPS
    LatLng effectiveTarget = _target;
    if (enablePrediction && _prevTargetTime != null) {
      final staleMs = now.difference(_prevTargetTime!).inMilliseconds;
      final spd = estimatedSpeedMps;
      if (staleMs > 200 && staleMs < _maxPredMs && spd > 0.8) {
        final extSec = staleMs / 1000.0 * 0.4;
        effectiveTarget = LatLng(
          _target.latitude + _velLat * extSec,
          _target.longitude + _velLng * extSec,
        );
      }
    }

    final lat = _current.latitude + (effectiveTarget.latitude - _current.latitude) * posLerp;
    final lng = _current.longitude + (effectiveTarget.longitude - _current.longitude) * posLerp;
    _current = LatLng(lat, lng);

    // Bearing: clamp to maxDegPerSec, shortest-arc path
    _currentBearing = BearingUtils.smoothBearing(
      _currentBearing, _targetBearing, dtMs / 1000.0,
      maxDegPerSec: bearingMaxDegPerSec);

    onTick(_current, _currentBearing);
  }

  static double computeBearing(LatLng a, LatLng b) =>
      BearingUtils.bearingBetween(a, b);
}
