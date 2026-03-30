import 'package:flutter/foundation.dart';
import '../models/lat_lng.dart';

import '../config/api_keys.dart';
import '../services/directions_service.dart';
import '../services/navigation_service.dart';

/// Convenience wrapper that fetches a [NavRoute] (with turn-by-turn steps)
/// using a fallback chain: Google+OSRM in parallel → Mapbox last resort.
class RouteService {
  static const _primaryTimeoutMs = 3000; // 3s — fast enough to feel instant

  /// Fetch a navigation-grade route between [origin] and [destination].
  ///
  /// Fires Google Directions and OSRM simultaneously, takes whichever
  /// resolves first with valid steps. Falls back to Mapbox only if both fail.
  /// Returns `null` only if all providers fail.
  static Future<NavRoute?> fetchNavRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final directions = DirectionsService(ApiKeys.webServices);

    // Helper that wraps a provider call with a timeout and swallows errors
    Future<NavRoute?> tryGoogle() async {
      try {
        final data = await directions.getRawDirectionsResponse(
          origin: origin,
          destination: destination,
        ).timeout(const Duration(milliseconds: _primaryTimeoutMs));
        if (data != null) {
          final route = NavigationService.fromDirectionsResponse(data);
          if (route != null && route.steps.isNotEmpty) {
            debugPrint('[RouteService] Google → ${route.steps.length} steps');
            return route;
          }
        }
      } catch (_) {}
      return null;
    }

    Future<NavRoute?> tryOsrm() async {
      try {
        final data = await directions.getRawOsrmResponse(
          origin: origin,
          destination: destination,
        ).timeout(const Duration(milliseconds: _primaryTimeoutMs));
        if (data != null) {
          final route = NavigationService.fromOsrmResponse(data);
          if (route != null && route.steps.isNotEmpty) {
            debugPrint('[RouteService] OSRM → ${route.steps.length} steps');
            return route;
          }
        }
      } catch (_) {}
      return null;
    }

    // 1+2. Race Google and OSRM — use whichever wins
    final results = await Future.wait([tryGoogle(), tryOsrm()]);
    for (final r in results) {
      if (r != null) return r;
    }

    // 3. Mapbox last resort (no extra timeout — already waited 3s above)
    try {
      debugPrint('[RouteService] Google+OSRM failed, trying Mapbox…');
      final mbxData = await directions.getRawMapboxResponse(
        origin: origin,
        destination: destination,
      );
      if (mbxData != null) {
        final route = NavigationService.fromMapboxResponse(mbxData);
        if (route != null && route.steps.isNotEmpty) {
          debugPrint('[RouteService] Mapbox → ${route.steps.length} steps');
          return route;
        }
      }
    } catch (_) {}

    debugPrint('[RouteService] All providers failed for $origin → $destination');
    return null;
  }
}
