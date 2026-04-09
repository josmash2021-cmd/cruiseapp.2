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
    if (_locAnimTo == null) return;
    // Exponential decay: close 12% of remaining gap per frame at 60fps
    // Frame-rate independent via delta-time normalization
    final dtMs = (elapsed - _locAnimStart).inMilliseconds.clamp(1, 100);
    _locAnimStart = elapsed;
    final dt = dtMs / 16.667; // normalize to 60fps
    const decay = 0.12;
    final factor = 1.0 - math.pow(1.0 - decay, dt);
    final cur = _interpolatedLatLng;
    final tgt = _locAnimTo!;
    final newLat = cur.latitude + (tgt.latitude - cur.latitude) * factor;
    final newLng = cur.longitude + (tgt.longitude - cur.longitude) * factor;
    _locAnimFrom = LatLng(newLat, newLng);
    _locAnimProgress = 0.0; // keep _interpolatedLatLng using _locAnimFrom directly
    // Update annotation at ~60fps (every 16ms)
    if (dtMs - _lastAnnotUpdateMs >= 16 || _lastAnnotUpdateMs == 0) {
      _lastAnnotUpdateMs = dtMs;
      _updateMiniMapAnnotation();
    }
    // Stop when close enough
    final latGap = (tgt.latitude - newLat).abs();
    final lngGap = (tgt.longitude - newLng).abs();
    if (latGap < 0.0000005 && lngGap < 0.0000005) {
      _locTicker?.stop();
    }
  }

  /// Start (or restart) smooth interpolation toward a new GPS target.
  void _animateToLocation(LatLng target) {
    // Set target — the ticker's exponential decay will glide toward it
    _locAnimTo = target;
    if (_locAnimFrom == null) _locAnimFrom = target;

    // Animate camera to target with smooth easing
    _miniMapController?.flyTo(
      mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(target.longitude, target.latitude))),
      mapbox.MapAnimationOptions(duration: 1200),
    );

    // Wake ticker if sleeping
    if (_locTicker != null && _locTicker!.isActive) {
      // Already running — just target update is enough
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
