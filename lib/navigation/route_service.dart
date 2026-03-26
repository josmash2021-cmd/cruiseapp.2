import 'package:flutter/foundation.dart';
import '../models/lat_lng.dart';

import '../config/api_keys.dart';
import '../services/directions_service.dart';
import '../services/navigation_service.dart';

/// Convenience wrapper that fetches a [NavRoute] (with turn-by-turn steps)
/// using a fallback chain: Google Directions → OSRM → Mapbox.
class RouteService {
  /// Fetch a navigation-grade route between [origin] and [destination].
  ///
  /// Tries Google Directions API first (best quality). If that fails,
  /// falls back to OSRM, then Mapbox — both with step-by-step instructions.
  /// Returns `null` only if all providers fail.
  static Future<NavRoute?> fetchNavRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final directions = DirectionsService(ApiKeys.webServices);

    // 1. Google Directions API (primary — best quality steps)
    try {
      final data = await directions.getRawDirectionsResponse(
        origin: origin,
        destination: destination,
      );
      if (data != null) {
        final route = NavigationService.fromDirectionsResponse(data);
        if (route != null && route.steps.isNotEmpty) {
          debugPrint('[RouteService] Google → ${route.steps.length} steps, ${route.overviewPolyline.length} pts');
          return route;
        }
      }
    } catch (_) {}

    // 2. OSRM fallback (free, good step quality)
    try {
      debugPrint('[RouteService] Google failed, trying OSRM…');
      final osrmData = await directions.getRawOsrmResponse(
        origin: origin,
        destination: destination,
      );
      if (osrmData != null) {
        final route = NavigationService.fromOsrmResponse(osrmData);
        if (route != null && route.steps.isNotEmpty) {
          debugPrint('[RouteService] OSRM → ${route.steps.length} steps, ${route.overviewPolyline.length} pts');
          return route;
        }
      }
    } catch (_) {}

    // 3. Mapbox fallback (uses access token already configured)
    try {
      debugPrint('[RouteService] OSRM failed, trying Mapbox…');
      final mbxData = await directions.getRawMapboxResponse(
        origin: origin,
        destination: destination,
      );
      if (mbxData != null) {
        final route = NavigationService.fromMapboxResponse(mbxData);
        if (route != null && route.steps.isNotEmpty) {
          debugPrint('[RouteService] Mapbox → ${route.steps.length} steps, ${route.overviewPolyline.length} pts');
          return route;
        }
      }
    } catch (_) {}

    debugPrint('[RouteService] All providers failed for $origin → $destination');
    return null;
  }
}
