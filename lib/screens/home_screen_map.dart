part of 'home_screen.dart';

// ════════════════════════════════════════════════════════════
//  MAP — mini map, location animation, annotations
// ════════════════════════════════════════════════════════════

extension _HomeScreenMap on _HomeScreenState {

  Future<void> _applyDarkNavyGoldTheme(mapbox.MapboxMap ctrl) async {
    await MapTheme.applyNavyGold(ctrl);
  }

  /// Ease-out cubic: fast start, gentle stop.
  double _easedProgress(double t) {
    final t1 = 1.0 - t;
    return 1.0 - t1 * t1 * t1;
  }
  void _onLocAnimTick(Duration elapsed) {
    if (_locAnimFrom == null || _locAnimTo == null) return;
    final dt = (elapsed - _locAnimStart).inMilliseconds;
    _locAnimProgress = (dt / _locAnimDurationMs).clamp(0.0, 1.0);
    // Throttle annotation updates to ~15fps (every 66ms) to avoid async backpressure
    if (dt - _lastAnnotUpdateMs >= 66) {
      _lastAnnotUpdateMs = dt;
      _updateMiniMapAnnotation();
    }
  }

  /// Start (or restart) smooth interpolation toward a new GPS target.
  void _animateToLocation(LatLng target) {
    // Start from current interpolated position (avoids jump)
    _locAnimFrom = _interpolatedLatLng;
    _locAnimTo = target;
    _locAnimProgress = 0.0;

    // Animate camera to target with smooth easing
    _miniMapController?.flyTo(
      mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(target.longitude, target.latitude))),
      mapbox.MapAnimationOptions(duration: _locAnimDurationMs),
    );

    // Reset animation timer relative to current ticker elapsed
    if (_locTicker != null && _locTicker!.isActive) {
      _locAnimNeedsRestart = true;
    } else {
      _locAnimNeedsRestart = true;
      _locTicker?.dispose();
      _locTicker = createTicker(_onLocAnimTickWrapper);
      _locTicker!.start();
    }
  }

  void _onLocAnimTickWrapper(Duration elapsed) {
    if (_locAnimNeedsRestart) {
      _locAnimStart = elapsed;
      _locAnimNeedsRestart = false;
    }
    _onLocAnimTick(elapsed);
  }
}
