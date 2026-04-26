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
    // ── Camera follow (Google Maps / Uber style) ──
    // Move the camera to the interpolated position EVERY frame so the
    // dot stays glued to the centre of the screen. Uses setCamera (not
    // flyTo / easeTo) so there's no per-call animation queue to fight
    // the per-frame writes; the smoothness comes from the per-frame
    // interpolated position itself.
    if (!_userPanningMap) {
      try {
        _miniMapController?.setCamera(
          mapbox.CameraOptions(
            center: mapbox.Point(
              coordinates: mapbox.Position(newLng, newLat),
            ),
          ),
        );
      } catch (_) {}
    }
    // Stop when close enough
    final latGap = (tgt.latitude - newLat).abs();
    final lngGap = (tgt.longitude - newLng).abs();
    if (latGap < 0.0000005 && lngGap < 0.0000005) {
      _locTicker?.stop();
    }
  }

  /// Start (or restart) smooth interpolation toward a new GPS target.
  /// Camera follow happens inside the per-frame ticker instead of here,
  /// so the camera glides at vsync (60-120 Hz) with the dot rather
  /// than playing a 1200 ms flyTo every GPS fix (which left the dot
  /// off-centre between updates and felt jumpy).
  void _animateToLocation(LatLng target) {
    _locAnimTo = target;
    if (_locAnimFrom == null) _locAnimFrom = target;

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
