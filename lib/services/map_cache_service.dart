import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import '../config/mapbox_config.dart';

/// Singleton that manages Mapbox offline tile caching using the native
/// OfflineManager + TileStore APIs. No extra packages needed — uses the
/// built-in mapbox_maps_flutter offline support.
///
/// Lifecycle:
///   1. [init] — called once at app startup (creates TileStore + downloads style)
///   2. [precacheArea] — silently caches tiles around a location
///   3. [precacheRoute] — caches pickup + dropoff areas when offer arrives
///   4. [cleanIfNeeded] — evicts old regions when cache exceeds quota
class MapCacheService {
  static final MapCacheService _instance = MapCacheService._internal();
  factory MapCacheService() => _instance;
  MapCacheService._internal();

  TileStore? _tileStore;
  OfflineManager? _offlineManager;
  bool _initialized = false;
  bool _stylePackLoaded = false;

  static const String _styleUri = 'mapbox://styles/mapbox/dark-v11';

  /// Max disk quota for tile cache (~200 MB).
  static const int _diskQuotaBytes = 200 * 1024 * 1024;

  /// Tile regions older than this are eligible for eviction.
  static const int _maxRegionAgeDays = 30;

  /// Max number of tile regions before cleanup.
  static const int _maxRegions = 50;

  bool get isInitialized => _initialized;
  TileStore? get tileStore => _tileStore;

  /// Initialize the tile store and start downloading the style pack.
  /// Safe to call multiple times — only initializes once.
  Future<void> init() async {
    if (_initialized) return;
    try {
      _tileStore = await TileStore.createDefault();
      _tileStore!.setDiskQuota(_diskQuotaBytes);

      _offlineManager = await OfflineManager.create();
      _initialized = true;

      // Download the style pack in the background (fonts, sprites, glyphs).
      // This ensures the map style renders offline even without tiles.
      _loadStylePack();

      debugPrint('[MapCache] initialized');
    } catch (e) {
      debugPrint('[MapCache] init failed: $e');
    }
  }

  /// Download the style pack (glyphs, sprites, etc.) so the map renders
  /// correctly even when fully offline.
  void _loadStylePack() {
    if (_offlineManager == null || _stylePackLoaded) return;
    _offlineManager!.loadStylePack(
      _styleUri,
      StylePackLoadOptions(acceptExpired: true),
      (progress) {
        if (progress.completedResourceCount == progress.requiredResourceCount &&
            progress.requiredResourceCount > 0) {
          _stylePackLoaded = true;
          debugPrint('[MapCache] style pack ready '
              '(${progress.completedResourceSize} bytes)');
        }
      },
    ).then((_) {
      // Style pack loaded successfully
    }).catchError((e) {
      debugPrint('[MapCache] style pack error: $e');
    });
  }

  /// Pre-cache tiles in a circular area around [center].
  ///
  /// [regionId] must be unique per region (used as tile region identifier).
  /// [minZoom] / [maxZoom] control the zoom levels to cache.
  /// [radiusKm] controls the area size.
  ///
  /// Runs silently in background — never blocks UI.
  Future<void> precacheArea({
    required String regionId,
    required double lat,
    required double lng,
    int minZoom = 10,
    int maxZoom = 16,
    double radiusKm = 5.0,
  }) async {
    if (!_initialized || _tileStore == null) return;

    try {
      // Build a bounding-box polygon around the center point.
      final geometry = _circleGeometry(lat, lng, radiusKm);

      final descriptors = [
        TilesetDescriptorOptions(
          styleURI: _styleUri,
          minZoom: minZoom,
          maxZoom: maxZoom,
          pixelRatio: 2.0,
        ),
      ];

      await _tileStore!.loadTileRegion(
        regionId,
        TileRegionLoadOptions(
          geometry: geometry,
          descriptorsOptions: descriptors,
          acceptExpired: true,
          networkRestriction: NetworkRestriction.NONE,
          metadata: <String, Object>{
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'lat': lat,
            'lng': lng,
          },
        ),
        (progress) {
          if (progress.completedResourceCount ==
                  progress.requiredResourceCount &&
              progress.requiredResourceCount > 0) {
            debugPrint('[MapCache] region "$regionId" cached '
                '(${progress.completedResourceCount} tiles)');
          }
        },
      );
    } catch (e) {
      debugPrint('[MapCache] precacheArea "$regionId" error: $e');
    }
  }

  /// Pre-cache tiles along a route (pickup area + dropoff area).
  /// Called when a ride offer arrives so the navigation map is instant.
  Future<void> precacheRoute({
    required String offerId,
    required double pickupLat,
    required double pickupLng,
    required double dropoffLat,
    required double dropoffLng,
  }) async {
    if (!_initialized) return;

    // Cache pickup area (tight, high zoom — street-level detail)
    precacheArea(
      regionId: 'offer_pickup_$offerId',
      lat: pickupLat,
      lng: pickupLng,
      minZoom: 14,
      maxZoom: 17,
      radiusKm: 1.0,
    );

    // Cache dropoff area
    precacheArea(
      regionId: 'offer_dropoff_$offerId',
      lat: dropoffLat,
      lng: dropoffLng,
      minZoom: 14,
      maxZoom: 17,
      radiusKm: 1.0,
    );
  }

  /// Remove old / excess tile regions to keep cache within quota.
  /// Safe to call periodically (e.g. on app start after a delay).
  Future<void> cleanIfNeeded() async {
    if (!_initialized || _tileStore == null) return;

    try {
      final regions = await _tileStore!.allTileRegions();
      if (regions.length <= _maxRegions) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      final staleThreshold =
          now - (_maxRegionAgeDays * 24 * 60 * 60 * 1000);

      int removed = 0;
      for (final region in regions) {
        // Remove offer-specific regions (they are transient)
        if (region.id.startsWith('offer_')) {
          await _tileStore!.removeRegion(region.id);
          removed++;
          continue;
        }

        // Remove regions older than threshold
        try {
          final meta = await _tileStore!.tileRegionMetadata(region.id);
          final createdAt = meta['createdAt'] as int? ?? 0;
          if (createdAt < staleThreshold) {
            await _tileStore!.removeRegion(region.id);
            removed++;
          }
        } catch (_) {
          // If we can't read metadata, leave it
        }
      }

      if (removed > 0) {
        debugPrint('[MapCache] cleaned $removed stale regions');
      }
    } catch (e) {
      debugPrint('[MapCache] cleanIfNeeded error: $e');
    }
  }

  /// Build a GeoJSON Polygon geometry approximating a circle.
  /// Returns the map that TileRegionLoadOptions.geometry expects.
  Map<String, Object> _circleGeometry(
      double lat, double lng, double radiusKm) {
    final coords = <List<double>>[];
    const segments = 16;
    for (int i = 0; i <= segments; i++) {
      final angle = (i / segments) * 2 * 3.14159265359;
      final dLat = (radiusKm / 111.32) * _cos(angle);
      final dLng =
          (radiusKm / (111.32 * _cos(lat * 3.14159265359 / 180))) * _sin(angle);
      coords.add([lng + dLng, lat + dLat]);
    }
    return <String, Object>{
      'type': 'Polygon',
      'coordinates': [coords],
    };
  }

  double _cos(double rad) {
    // Inline Taylor approximation — avoids dart:math import for lightweight usage
    final x = rad % (2 * 3.14159265359);
    final x2 = x * x;
    return 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720;
  }

  double _sin(double rad) => _cos(rad - 1.5707963268);
}
