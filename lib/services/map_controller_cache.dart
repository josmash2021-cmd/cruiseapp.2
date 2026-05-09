import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

/// Singleton cache for Mapbox map controllers.
/// 
/// Creating a MapWidget from scratch takes 1-2 seconds (style download,
/// tile loading, annotation manager setup). This cache keeps the controller
/// alive and reuses it across screens, making navigation instant.
/// 
/// Usage:
///   final controller = await MapControllerCache.instance.getController();
///   // Use controller... when done, don't dispose it — just release it.
///   MapControllerCache.instance.release();
class MapControllerCache {
  MapControllerCache._();
  static final MapControllerCache _instance = MapControllerCache._();
  static MapControllerCache get instance => _instance;

  mapbox.MapboxMap? _mapboxMap;
  bool _isAcquired = false;

  /// Returns true if a controller is already cached and ready.
  bool get hasController => _mapboxMap != null;

  /// Acquire the cached controller. If none exists, returns null
  /// and the caller should create a new MapWidget.
  mapbox.MapboxMap? acquire() {
    if (_mapboxMap != null && !_isAcquired) {
      _isAcquired = true;
      debugPrint('[MapCache] Controller acquired (reuse)');
      return _mapboxMap;
    }
    return null;
  }

  /// Store a controller for future reuse.
  void cache(mapbox.MapboxMap controller) {
    // Only cache if we don't have one — prevents overwriting a valid
    // cached controller with a stale one from a different screen.
    _mapboxMap ??= controller;
    // Mark as available for reuse (in case it was acquired before)
    _isAcquired = false;
    debugPrint('[MapCache] Controller cached and released');
  }

  /// Release the controller so another screen can acquire it.
  void release() {
    _isAcquired = false;
    debugPrint('[MapCache] Controller released');
  }

  /// Permanently dispose the cached controller (e.g. on logout).
  void dispose() {
    _isAcquired = false;
    _mapboxMap = null;
    debugPrint('[MapCache] Controller disposed');
  }
}
