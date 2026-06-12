part of 'home_screen.dart';

// ════════════════════════════════════════════════════════════
//  MAP — mini map, location animation, annotations
// ════════════════════════════════════════════════════════════

extension _HomeScreenMap on _HomeScreenState {

  Future<void> _applyDarkNavyGoldTheme(mapbox.MapboxMap ctrl) async {
    await MapTheme.applyNavyGold(ctrl);
  }

  /// Ease-out cubic: fast start, gentle stop.
  /// Used by driver-car animation; rider dot uses GoldLocationDot/SmoothMotion.
  double _easedProgress(double t) {
    final t1 = 1.0 - t;
    return 1.0 - t1 * t1 * t1;
  }

  /// Recenter the camera on the rider at most once per [interval].
  /// Uses the interpolated dot position so the camera and annotation stay
  /// in sync. Called from the GPS stream so the map follows the rider
  /// without being driven by the 60fps dot ticker.
  void _throttledCameraRecenter({Duration interval = const Duration(milliseconds: 500)}) {
    if (_miniMapController == null) return;
    final lat = _miniDot.lat ?? _currentLatLng?.latitude;
    final lng = _miniDot.lng ?? _currentLatLng?.longitude;
    if (lat == null || lng == null) return;

    final now = DateTime.now();
    if (now.difference(_lastCameraRecenter) < interval) return;
    _lastCameraRecenter = now;

    final point = safePoint(lng, lat);
    if (point == null) return;

    try {
      _miniMapController!.flyTo(
        mapbox.CameraOptions(
          center: point,
          zoom: 15.0,
          pitch: 0,
          bearing: 0,
        ),
        mapbox.MapAnimationOptions(duration: 400),
      );
    } catch (e) {
      debugPrint('[Map] Camera recenter failed: $e');
    }
  }
}
