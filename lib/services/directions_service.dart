import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/lat_lng.dart';

class RouteResult {
  final List<LatLng> points;
  final String distanceText;
  final int distanceMeters;
  final String durationText;
  final String startAddress;
  final String endAddress;

  const RouteResult({
    required this.points,
    required this.distanceText,
    required this.distanceMeters,
    required this.durationText,
    required this.startAddress,
    required this.endAddress,
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

    final res = await http.get(uri);
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

  Future<RouteResult?> getRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final data = await _requestDirectionsWithFallbacks(
      origin: origin,
      destination: destination,
    );
    if (data == null) {
      return _requestOsrmRoute(origin: origin, destination: destination);
    }

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
      final anchored = _anchorRoutePoints(detailedPoints, origin, destination);
      return RouteResult(
        points: anchored,
        distanceText: distanceText,
        distanceMeters: distanceMeters,
        durationText: durationText,
        startAddress: startAddress,
        endAddress: endAddress,
      );
    }

    final overview = route['overview_polyline'];
    final points = overview?['points']?.toString();
    if (points == null || points.isEmpty) return null;

    final decoded = _decodePolyline(points);
    final anchored = _anchorRoutePoints(decoded, origin, destination);

    return RouteResult(
      points: anchored,
      distanceText: distanceText,
      distanceMeters: distanceMeters,
      durationText: durationText,
      startAddress: startAddress,
      endAddress: endAddress,
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
        'steps': 'false',
        'geometries': 'polyline',
      });

      final res = await http.get(uri);
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
      final geometry = bestRoute['geometry']?.toString();
      final durationSeconds = (bestRoute['duration'] as num?)?.toInt() ?? 0;
      final distanceMeters = (bestRoute['distance'] as num?)?.toInt() ?? 0;
      if (geometry == null || geometry.isEmpty) return null;

      final decoded = _decodePolyline(geometry);
      if (decoded.isEmpty) return null;

      final anchored = _anchorRoutePoints(decoded, origin, destination);
      return RouteResult(
        points: anchored,
        distanceText: _metersToMilesText(distanceMeters),
        distanceMeters: distanceMeters,
        durationText: _durationTextFromSeconds(durationSeconds),
        startAddress: '',
        endAddress: '',
      );
    } catch (_) {
      return null;
    }
  }

  List<LatLng> _anchorRoutePoints(
    List<LatLng> input,
    LatLng origin,
    LatLng destination,
  ) {
    if (input.isEmpty) return [origin, destination];

    final out = <LatLng>[];
    out.add(origin);
    out.addAll(input);
    out.add(destination);

    return out;
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
        final res = await http.get(uri);
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
}
