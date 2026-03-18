import '../models/lat_lng.dart';

import '../config/api_keys.dart';
import '../services/directions_service.dart';
import '../services/navigation_service.dart';

/// Convenience wrapper that fetches a [NavRoute] (with turn-by-turn steps)
/// from the Google Directions API, suitable for the driver navigation page.
class RouteService {
  /// Fetch a navigation-grade route between [origin] and [destination].
  ///
  /// Returns a [NavRoute] with overview polyline and step-by-step instructions,
  /// or `null` if the request fails.
  static Future<NavRoute?> fetchNavRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final directions = DirectionsService(ApiKeys.webServices);
      final data = await directions.getRawDirectionsResponse(
        origin: origin,
        destination: destination,
      );
      if (data == null) return null;
      return NavigationService.fromDirectionsResponse(data);
    } catch (_) {
      return null;
    }
  }
}
