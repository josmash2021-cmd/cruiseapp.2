import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/lat_lng.dart';
import '../config/mapbox_config.dart';

class RouteResult {
  final List<LatLng> points;
  final String distanceText;
  final int distanceMeters;
  final String durationText;
  final String startAddress;
  final String endAddress;

  /// Route duration in seconds from the directions API (includes traffic when
  /// available). Null when the provider did not return a usable value.
  final int? durationSeconds;

  const RouteResult({
    required this.points,
    required this.distanceText,
    required this.distanceMeters,
    required this.durationText,
    required this.startAddress,
    required this.endAddress,
    this.durationSeconds,
  });
}

class DistanceEstimate {
  final double miles;
  final String durationText;

  const DistanceEstimate({required this.miles, required this.durationText});
}

class DirectionsService {
  final String apiKey;
  DirectionsService(this.apiKey);

  // In-memory route cache: same origin+destination = instant hit
  // LRU eviction: max 50 entries; oldest accessed entry is removed when full.
  static const _cacheMaxSize = 50;
  static final Map<String, RouteResult> _routeCache = {};
  static final Map<String, Map<String, DistanceEstimate>> _distanceCache = {};
  static const _cacheMaxAge = Duration(minutes: 5);
  static final Map<String, DateTime> _cacheTimes = {};
  /// Tracks last-access time for LRU eviction.
  static final Map<String, DateTime> _cacheAccessTimes = {};

  /// Clear all cached routes (call on logout or location change)
  static void clearCache() {
    _routeCache.clear();
    _distanceCache.clear();
    _cacheTimes.clear();
    _cacheAccessTimes.clear();
  }

  String _cacheKey(LatLng a, LatLng b) =>
      '${a.latitude.toStringAsFixed(3)},${a.longitude.toStringAsFixed(3)}_'
      '${b.latitude.toStringAsFixed(3)},${b.longitude.toStringAsFixed(3)}';

  bool _isCacheValid(String key) {
    final t = _cacheTimes[key];
    return t != null && DateTime.now().difference(t) < _cacheMaxAge;
  }

  Future<Map<String, DistanceEstimate>> getDistanceEstimates({
    required LatLng origin,
    required List<LatLng> destinations,
  }) async {
    if (destinations.isEmpty) return {};

    final destinationsParam = destinations
        .map((point) => '${point.latitude},${point.longitude}')
        .join('|');

    final uri =
        Uri.https('maps.googleapis.com', '/maps/api/distancematrix/json', {
          'origins': '${origin.latitude},${origin.longitude}',
          'destinations': destinationsParam,
          'mode': 'driving',
          'units': 'imperial',
          'key': apiKey,
        });

    final res = await http.get(uri).timeout(const Duration(seconds: 5));
    final data = jsonDecode(res.body);
    if (data['status'] != 'OK') return {};

    final rows = data['rows'] as List?;
    if (rows == null || rows.isEmpty) return {};

    final elements = rows.first['elements'] as List?;
    if (elements == null) return {};

    final result = <String, DistanceEstimate>{};
    for (var i = 0; i < destinations.length && i < elements.length; i++) {
      final element = elements[i];
      if (element['status'] != 'OK') continue;

      final meters = (element['distance']?['value'] as num?)?.toDouble();
      final durationText = element['duration']?['text']?.toString();
      if (meters == null || durationText == null || durationText.isEmpty) {
        continue;
      }

      result[_pointKey(destinations[i])] = DistanceEstimate(
        miles: meters / 1609.344,
        durationText: durationText,
      );
    }

    return result;
  }

  /// Get the raw Directions API response (for turn-by-turn parsing).
  /// Returns the full JSON map with 'status', 'routes', etc.
  Future<Map<String, dynamic>?> getRawDirectionsResponse({
    required LatLng origin,
    required LatLng destination,
  }) async {
    return _requestDirectionsWithFallbacks(
      origin: origin,
      destination: destination,
    );
  }

  /// Get raw OSRM response with steps for turn-by-turn fallback.
  Future<Map<String, dynamic>?> getRawOsrmResponse({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final path =
          '/route/v1/driving/${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'alternatives': 'false',
        'steps': 'true',
        'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 6));
      final data = jsonDecode(res.body);
      if (data is! Map<String, dynamic>) return null;
      if (data['code']?.toString().toUpperCase() != 'OK') return null;
      return data;
    } catch (_) {
      return null;
    }
  }

  /// Get raw Mapbox response with steps for turn-by-turn fallback.
  Future<Map<String, dynamic>?> getRawMapboxResponse({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final url = Uri.parse(
        'https://api.mapbox.com/directions/v5/mapbox/driving/'
        '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}'
        '?geometries=geojson&overview=full&steps=true&annotations=maxspeed'
        '&access_token=${MapboxConfig.accessToken}',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is! Map<String, dynamic>) return null;
      return data;
    } catch (_) {
      return null;
    }
  }

  Future<RouteResult?> getRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    // Check route cache first (instant return)
    final key = _cacheKey(origin, destination);
    if (_routeCache.containsKey(key) && _isCacheValid(key)) {
      debugPrint('[Route] Cache hit for $key');
      _cacheAccessTimes[key] = DateTime.now(); // LRU: mark as recently used
      return _routeCache[key]!;
    }

    // Clean up old cache entries periodically (10% chance on each call)
    if (math.Random().nextDouble() < 0.1) {
      cleanupOldCache();
    }

    debugPrint('[Route] Fetching route: origin=${origin.latitude},${origin.longitude} → dest=${destination.latitude},${destination.longitude}');

    // Retry logic: try up to 2 times with exponential backoff
    RouteResult? result;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        // Exponential backoff: wait 500ms on retry
        await Future.delayed(Duration(milliseconds: 500 * attempt));
        debugPrint('[Route] Retry attempt ${attempt + 1}');
      }

      // Launch all three providers in PARALLEL — take the first success
      final googleFuture = _requestDirectionsWithFallbacks(
        origin: origin,
        destination: destination,
      ).then((data) {
        if (data == null) return null;
        return _parseGoogleRoute(data, origin, destination);
      }).timeout(const Duration(seconds: 6), onTimeout: () => null);

      final osrmFuture = _requestOsrmRoute(origin: origin, destination: destination)
          .timeout(const Duration(seconds: 6), onTimeout: () => null);

      final mapboxFuture = _requestMapboxRoute(origin: origin, destination: destination)
          .timeout(const Duration(seconds: 8), onTimeout: () => null);

      // Wait for all, take the first non-null result (prefer Mapbox > Google > OSRM)
      // Mapbox route aligns best with Mapbox map tiles for accurate road overlay
      final results = await Future.wait([googleFuture, osrmFuture, mapboxFuture]);
      final mapbox = results[2];
      final google = results[0];
      final osrm = results[1];
      if (mapbox != null) {
        debugPrint('[Route] Using Mapbox provider (${mapbox.points.length} points)');
        result = mapbox;
      } else if (google != null) {
        debugPrint('[Route] Mapbox failed, using Google provider (${google.points.length} points)');
        result = google;
      } else if (osrm != null) {
        debugPrint('[Route] Mapbox+Google failed, using OSRM provider (${osrm.points.length} points)');
        result = osrm;
      }

      if (result != null) {
        debugPrint('[Route] Got route with ${result.points.length} points (attempt ${attempt + 1})');
        // LRU eviction: remove oldest entry when cache exceeds max size
        if (_routeCache.length >= _cacheMaxSize && !_routeCache.containsKey(key)) {
          _evictOldestCacheEntry();
        }
        _routeCache[key] = result;
        _cacheTimes[key] = DateTime.now();
        _cacheAccessTimes[key] = DateTime.now();
        return result;
      }
    }

    debugPrint('[Route] All providers failed after retries');
    return null;
  }

  /// Parse a Google Directions JSON response into a RouteResult.
  RouteResult? _parseGoogleRoute(
    Map<String, dynamic> data,
    LatLng origin,
    LatLng destination,
  ) {
    final routes = data['routes'] as List?;
    if (routes == null || routes.isEmpty) return null;

    Map<String, dynamic>? route;
    var bestDuration = 1 << 30;
    for (final candidate in routes) {
      if (candidate is! Map<String, dynamic>) continue;
      final candidateLegs = candidate['legs'] as List?;
      if (candidateLegs == null || candidateLegs.isEmpty) continue;

      var totalSeconds = 0;
      for (final leg in candidateLegs) {
        final trafficValue = leg['duration_in_traffic']?['value'];
        final normalValue = leg['duration']?['value'];
        totalSeconds += ((trafficValue ?? normalValue) as num?)?.toInt() ?? 0;
      }

      if (totalSeconds == 0) continue;
      if (totalSeconds < bestDuration) {
        bestDuration = totalSeconds;
        route = candidate;
      }
    }

    route ??= routes.first as Map<String, dynamic>;
    final legs = route['legs'] as List?;
    if (legs == null || legs.isEmpty) return null;

    final firstLeg = legs.first;
    final lastLeg = legs.last;

    var totalDistanceMeters = 0;
    var totalDurationSeconds = 0;
    for (final leg in legs) {
      totalDistanceMeters += (leg['distance']?['value'] as num?)?.toInt() ?? 0;
      totalDurationSeconds +=
          ((leg['duration_in_traffic']?['value'] ?? leg['duration']?['value'])
                  as num?)
              ?.toInt() ??
          0;
    }

    final distanceMeters = totalDistanceMeters;
    final distanceText = _metersToMilesText(distanceMeters);
    final durationText = _durationTextFromSeconds(totalDurationSeconds);
    final startAddress = firstLeg['start_address']?.toString() ?? '';
    final endAddress = lastLeg['end_address']?.toString() ?? '';

    final detailedPoints = <LatLng>[];
    for (final leg in legs) {
      final steps = (leg['steps'] as List?) ?? [];
      for (final step in steps) {
        final polyline = step['polyline'];
        final encoded = polyline?['points']?.toString();
        if (encoded == null || encoded.isEmpty) continue;
        detailedPoints.addAll(_decodePolyline(encoded));
      }
    }

    if (detailedPoints.isNotEmpty) {
      final validated = _validatePoints(detailedPoints);
      final anchored = _anchorRoutePoints(validated, origin, destination);
      debugPrint('[Route] Google steps → ${anchored.length} points. First: ${anchored.first} Last: ${anchored.last}');
      return RouteResult(
        points: anchored,
        distanceText: distanceText,
        distanceMeters: distanceMeters,
        durationText: durationText,
        startAddress: startAddress,
        endAddress: endAddress,
        durationSeconds: totalDurationSeconds > 0 ? totalDurationSeconds : null,
      );
    }

    final overview = route['overview_polyline'];
    final points = overview?['points']?.toString();
    if (points == null || points.isEmpty) return null;

    final decoded = _decodePolyline(points);
    final validated = _validatePoints(decoded);
    final anchored = _anchorRoutePoints(validated, origin, destination);
    debugPrint('[Route] Google overview → ${anchored.length} points. First: ${anchored.first} Last: ${anchored.last}');

    return RouteResult(
      points: anchored,
      distanceText: distanceText,
      distanceMeters: distanceMeters,
      durationText: durationText,
      startAddress: startAddress,
      endAddress: endAddress,
      durationSeconds: totalDurationSeconds > 0 ? totalDurationSeconds : null,
    );
  }

  Future<RouteResult?> _requestOsrmRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final path =
          '/route/v1/driving/${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'alternatives': 'true',
        'steps': 'true',
        'geometries': 'polyline',
      });

      final res = await http.get(uri).timeout(const Duration(seconds: 6));
      final data = jsonDecode(res.body);
      if (data is! Map<String, dynamic>) return null;
      if (data['code']?.toString().toUpperCase() != 'OK') return null;

      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;

      Map<String, dynamic>? bestRoute;
      var bestDuration = double.infinity;
      for (final item in routes) {
        if (item is! Map<String, dynamic>) continue;
        final duration = (item['duration'] as num?)?.toDouble();
        if (duration == null || duration <= 0) continue;
        if (duration < bestDuration) {
          bestDuration = duration;
          bestRoute = item;
        }
      }

      bestRoute ??= routes.first as Map<String, dynamic>;
      final durationSeconds = (bestRoute['duration'] as num?)?.toInt() ?? 0;
      final distanceMeters = (bestRoute['distance'] as num?)?.toInt() ?? 0;

      // Prefer step-level geometry — follows every road segment precisely
      final detailedPoints = <LatLng>[];
      final legs = bestRoute['legs'] as List?;
      if (legs != null) {
        for (final leg in legs) {
          final steps = (leg['steps'] as List?) ?? [];
          for (final step in steps) {
            final stepGeometry = step['geometry']?.toString();
            if (stepGeometry != null && stepGeometry.isNotEmpty) {
              detailedPoints.addAll(_decodePolyline(stepGeometry));
            }
          }
        }
      }

      List<LatLng> decoded;
      if (detailedPoints.length >= 2) {
        decoded = detailedPoints;
        debugPrint('[Route] OSRM steps → ${decoded.length} points');
      } else {
        final geometry = bestRoute['geometry']?.toString();
        if (geometry == null || geometry.isEmpty) return null;
        decoded = _decodePolyline(geometry);
        debugPrint('[Route] OSRM overview → ${decoded.length} points');
      }
      if (decoded.isEmpty) return null;

      final validated = _validatePoints(decoded);
      final anchored = _anchorRoutePoints(validated, origin, destination);
      return RouteResult(
        points: anchored,
        distanceText: _metersToMilesText(distanceMeters),
        distanceMeters: distanceMeters,
        durationText: _durationTextFromSeconds(durationSeconds),
        startAddress: '',
        endAddress: '',
        durationSeconds: durationSeconds > 0 ? durationSeconds : null,
      );
    } catch (_) {
      return null;
    }
  }

  Future<RouteResult?> _requestMapboxRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      // Mapbox expects coordinates as longitude,latitude
      final url = Uri.parse(
        'https://api.mapbox.com/directions/v5/mapbox/driving/'
        '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}'
        '?geometries=geojson&overview=full&steps=true&annotations=maxspeed'
        '&access_token=${MapboxConfig.accessToken}',
      );
      debugPrint('[Route] Mapbox request URL: $url');
      final res = await http.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;

      final route = routes[0] as Map<String, dynamic>;
      final distanceMeters = (route['distance'] as num?)?.toInt() ?? 0;
      final durationSeconds = (route['duration'] as num?)?.toInt() ?? 0;

      // Prefer step-level geometry — follows every road segment precisely
      final detailedPoints = <LatLng>[];
      final legs = route['legs'] as List?;
      if (legs != null) {
        for (final leg in legs) {
          final steps = (leg['steps'] as List?) ?? [];
          for (final step in steps) {
            final stepCoords = step['geometry']?['coordinates'] as List?;
            if (stepCoords != null) {
              detailedPoints.addAll(stepCoords.map(
                (c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
              ));
            }
          }
        }
      }

      // Fall back to overview geometry if steps unavailable
      List<LatLng> points;
      if (detailedPoints.length >= 2) {
        points = detailedPoints;
        debugPrint('[Route] Mapbox steps → ${points.length} points');
      } else {
        final coords = route['geometry']?['coordinates'] as List?;
        if (coords == null || coords.isEmpty) return null;
        points = coords
            .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
            .toList();
        debugPrint('[Route] Mapbox overview → ${points.length} points');
      }

      final validated = _validatePoints(points);
      final anchored = _anchorRoutePoints(validated, origin, destination);
      return RouteResult(
        points: anchored,
        distanceText: _metersToMilesText(distanceMeters),
        distanceMeters: distanceMeters,
        durationText: _durationTextFromSeconds(durationSeconds),
        startAddress: '',
        endAddress: '',
        durationSeconds: durationSeconds > 0 ? durationSeconds : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Filter out points with invalid lat/lng or outliers that jump off-road.
  List<LatLng> _validatePoints(List<LatLng> points) {
    // Step 1: remove globally invalid coordinates
    final valid = points.where((p) {
      final validLat = p.latitude >= -90 && p.latitude <= 90;
      final validLng = p.longitude >= -180 && p.longitude <= 180;
      if (!validLat || !validLng) {
        debugPrint('[Route] Filtered invalid point: $p');
        return false;
      }
      return true;
    }).toList();

    if (valid.length < 3) return valid;

    // Step 2: remove extreme outlier points (>5km from both neighbors)
    // Only filter truly broken coordinates, not legitimate highway waypoints
    final cleaned = <LatLng>[valid.first];
    for (int i = 1; i < valid.length - 1; i++) {
      final prev = valid[i - 1];
      final curr = valid[i];
      final next = valid[i + 1];
      final dPrev = _haversineMeters(prev, curr);
      final dNext = _haversineMeters(curr, next);
      final dDirect = _haversineMeters(prev, next);
      // Only filter if point is >5km from both neighbors AND removing it
      // shortens the path by >70% — a clear coordinate glitch
      if (dPrev > 5000 && dNext > 5000 && dDirect < (dPrev + dNext) * 0.15) {
        debugPrint('[Route] Filtered outlier point: $curr (dPrev=${dPrev.toInt()}m dNext=${dNext.toInt()}m)');
        continue;
      }
      cleaned.add(curr);
    }
    cleaned.add(valid.last);
    return cleaned;
  }

  /// Haversine distance in meters between two points.
  static double _haversineMeters(LatLng a, LatLng b) {
    const r = 6371000.0; // Earth radius in meters
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sinLat = math.sin(dLat / 2);
    final sinLng = math.sin(dLng / 2);
    final h = sinLat * sinLat +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            sinLng * sinLng;
    return 2 * r * math.asin(math.sqrt(h));
  }

  /// Return the route points as-is from the directions API.
  /// APIs already snap start/end to the nearest road — adding raw user
  /// coordinates would create off-road straight-line segments.
  List<LatLng> _anchorRoutePoints(
    List<LatLng> input,
    LatLng origin,
    LatLng destination,
  ) {
    if (input.isEmpty) return [origin, destination];
    return input;
  }

  List<LatLng> _decodePolyline(String poly) {
    List<LatLng> points = [];
    int index = 0, len = poly.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = poly.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = poly.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

  String _pointKey(LatLng point) {
    return '${point.latitude.toStringAsFixed(6)},${point.longitude.toStringAsFixed(6)}';
  }

  Future<Map<String, dynamic>?> _requestDirectionsWithFallbacks({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final variants = <Map<String, String>>[
      {
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'key': apiKey,
        'mode': 'driving',
        'departure_time': 'now',
        'traffic_model': 'best_guess',
        'alternatives': 'true',
      },
      {
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'key': apiKey,
        'mode': 'driving',
        'alternatives': 'true',
      },
      {
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'key': apiKey,
        'mode': 'driving',
      },
    ];

    for (final query in variants) {
      try {
        final uri = Uri.https(
          'maps.googleapis.com',
          '/maps/api/directions/json',
          query,
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 5));
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic> && data['status'] == 'OK') {
          return data;
        }
      } catch (_) {}
    }

    return null;
  }

  String _metersToMilesText(int meters) {
    final miles = meters / 1609.344;
    return '${miles.toStringAsFixed(2)} mi';
  }

  String _durationTextFromSeconds(int seconds) {
    if (seconds <= 0) return '-- min';
    final minutes = (seconds / 60).round().clamp(1, 24 * 60);
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    if (rem == 0) return '$hours h';
    return '$hours h $rem min';
  }

  /// Get an INSTANT estimated route (straight line) while the real route is being fetched.
  /// This provides immediate visual feedback and prevents UI from "thinking" too long.
  RouteResult getEstimatedRoute({
    required LatLng origin,
    required LatLng destination,
  }) {
    // Calculate straight-line distance using haversine
    final distanceMeters = _haversineMeters(origin, destination).toInt();
    final distanceText = _metersToMilesText(distanceMeters);
    
    // Estimate duration: assume 30 mph average city speed (13.4 m/s)
    // Add 20% buffer for turns and traffic
    final estimatedSeconds = ((distanceMeters / 13.4) * 1.2).toInt();
    final durationText = _durationTextFromSeconds(estimatedSeconds);
    
    // Just 2 endpoints — the UI will draw a straight line between them.
    // This is only a temporary placeholder until the real route loads.
    final points = <LatLng>[origin, destination];
    
    debugPrint('[Route] Generated estimated route: $distanceText, $durationText (${points.length} points)');
    
    return RouteResult(
      points: points,
      distanceText: distanceText,
      distanceMeters: distanceMeters,
      durationText: durationText,
      startAddress: 'Origin',
      endAddress: 'Destination',
      durationSeconds: estimatedSeconds > 0 ? estimatedSeconds : null,
    );
  }

  /// Evict the least-recently-accessed cache entry (LRU).
  static void _evictOldestCacheEntry() {
    if (_cacheAccessTimes.isEmpty) {
      // Fallback: remove the first key in insertion order
      if (_routeCache.isNotEmpty) {
        final oldest = _routeCache.keys.first;
        _routeCache.remove(oldest);
        _cacheTimes.remove(oldest);
        _cacheAccessTimes.remove(oldest);
        debugPrint('[Route] LRU evicted (fallback): $oldest');
      }
      return;
    }
    // Find the key with the earliest access time
    String? oldestKey;
    DateTime? oldestTime;
    _cacheAccessTimes.forEach((key, time) {
      if (oldestTime == null || time.isBefore(oldestTime!)) {
        oldestKey = key;
        oldestTime = time;
      }
    });
    if (oldestKey != null) {
      _routeCache.remove(oldestKey);
      _cacheTimes.remove(oldestKey);
      _cacheAccessTimes.remove(oldestKey);
      debugPrint('[Route] LRU evicted: $oldestKey');
    }
  }

  /// Clean up old cache entries to prevent memory bloat
  static void cleanupOldCache() {
    final now = DateTime.now();
    final keysToRemove = <String>[];

    _cacheTimes.forEach((key, time) {
      if (now.difference(time) > _cacheMaxAge) {
        keysToRemove.add(key);
      }
    });

    for (final key in keysToRemove) {
      _routeCache.remove(key);
      _cacheTimes.remove(key);
      _cacheAccessTimes.remove(key);
      debugPrint('[Route] Cleaned up old cache entry: $key');
    }
  }
}
