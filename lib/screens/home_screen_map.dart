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
    if (!mounted || _miniMapController == null) return;
    final lat = _miniDot.lat ?? _currentLatLng?.latitude;
    final lng = _miniDot.lng ?? _currentLatLng?.longitude;
    if (lat == null || lng == null) return;

    final now = DateTime.now();
    if (now.difference(_lastCameraRecenter) < interval) return;
    _lastCameraRecenter = now;

    final point = safePoint(lng, lat);
    if (point == null) return;

    try {
      unawaited(_miniMapController!.flyTo(
        mapbox.CameraOptions(
          center: point,
          zoom: 15.0,
          pitch: 0,
          bearing: 0,
        ),
        mapbox.MapAnimationOptions(duration: 400),
      ));
    } catch (e) {
      if (kDebugMode) debugPrint('[Map] Camera recenter failed: $e');
    }
  }

  /// Start watchdogs that keep the GPS stream and rider dot healthy.
  /// Call from initState after building the dot.
  void _startLocationWatchdogs() {
    // Start the grace period now so the watchdog doesn't fire before the
    // first GPS fix has had a chance to arrive.
    _lastGpsFixAt = DateTime.now();

    _gpsStreamWatchdog?.cancel();
    _gpsStreamWatchdog = Timer.periodic(const Duration(seconds: _gpsWatchdogSec), (_) {
      _checkGpsStreamHealth();
    });

    _dotDriftWatchdog?.cancel();
    _dotDriftWatchdog = Timer.periodic(const Duration(seconds: _dotDriftWatchdogSec), (_) {
      _checkDotDrift();
    });
  }

  /// Stop the self-healing watchdogs. Call from dispose.
  void _stopLocationWatchdogs() {
    _gpsStreamWatchdog?.cancel();
    _gpsStreamWatchdog = null;
    _dotDriftWatchdog?.cancel();
    _dotDriftWatchdog = null;
  }

  /// If no GPS fix has arrived recently, restart the position stream.
  /// Geolocator streams can die silently on some Android/iOS devices.
  /// Only restarts if a stream was already started (i.e., permission granted).
  void _checkGpsStreamHealth() {
    if (!mounted || _locationSub == null || _fetchingLocation) return;
    final elapsed = DateTime.now().difference(_lastGpsFixAt).inSeconds;
    if (elapsed < _gpsWatchdogSec) return;
    _fetchCurrentLocation();
  }

  /// If the interpolated dot has drifted too far from the raw GPS fix,
  /// snap it back. This prevents the dot from getting stuck if the
  /// SmoothMotion or annotation update pipeline silently fails.
  void _checkDotDrift() {
    if (!mounted || _currentLatLng == null) return;
    final dotLat = _miniDot.lat;
    final dotLng = _miniDot.lng;
    if (dotLat == null || dotLng == null) return;

    final drift = _haversineMeters(
      dotLat, dotLng,
      _currentLatLng!.latitude, _currentLatLng!.longitude,
    );
    if (drift <= _maxDotDriftMeters) return;

    _miniDot.snapTo(_currentLatLng!.latitude, _currentLatLng!.longitude);
    unawaited(_updateMiniMapAnnotation());
  }

  /// Haversine distance in meters between two lat/lng pairs.
  double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
    const R = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * R * math.asin(math.sqrt(a));
  }
}
