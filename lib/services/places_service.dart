import 'dart:convert';
import 'dart:math' show sin, cos, sqrt, atan2, pi;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:geocoding/geocoding.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

// ─── Place type enum for smart icons ─────────────────────────────────

enum PlaceType { airport, hotel, hospital, education, commerce, home }

// ─── Models (same interface — all screens keep working) ──────────────

class PlaceSuggestion {
  final String description;
  final String placeId;
  final double? lat;
  final double? lng;
  final double? distanceMiles;
  final String? etaText;
  final List<String> types;
  PlaceSuggestion({
    required this.description,
    required this.placeId,
    this.lat,
    this.lng,
    this.distanceMiles,
    this.etaText,
    this.types = const [],
  });

  PlaceSuggestion copyWith({
    String? description,
    String? placeId,
    double? lat,
    double? lng,
    double? distanceMiles,
    String? etaText,
    List<String>? types,
  }) {
    return PlaceSuggestion(
      description: description ?? this.description,
      placeId: placeId ?? this.placeId,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      distanceMiles: distanceMiles ?? this.distanceMiles,
      etaText: etaText ?? this.etaText,
      types: types ?? this.types,
    );
  }

  /// Detect place type from Google Places type tags.
  PlaceType get placeType {
    if (types.contains('airport')) return PlaceType.airport;
    if (types.contains('lodging') || types.contains('hotel')) {
      return PlaceType.hotel;
    }
    if (types.contains('hospital') || types.contains('health')) {
      return PlaceType.hospital;
    }
    if (types.contains('university') || types.contains('school')) {
      return PlaceType.education;
    }
    if (types.contains('shopping_mall') || types.contains('store')) {
      return PlaceType.commerce;
    }
    return PlaceType.home;
  }

  /// Smart icon based on place type.
  IconData get icon {
    switch (placeType) {
      case PlaceType.airport:
        return Icons.local_airport_rounded;
      case PlaceType.hotel:
        return Icons.hotel_rounded;
      case PlaceType.hospital:
        return Icons.local_hospital_rounded;
      case PlaceType.education:
        return Icons.school_rounded;
      case PlaceType.commerce:
        return Icons.storefront_rounded;
      case PlaceType.home:
        return Icons.location_on_rounded;
    }
  }
}

class PlaceDetails {
  final String address;
  final double lat;
  final double lng;
  PlaceDetails({required this.address, required this.lat, required this.lng});
}

/// Google Places–powered service.
///
/// - Autocomplete: Google Places Autocomplete (full coverage — airports,
///   hotels, hospitals, universities, malls, businesses, addresses).
/// - Details: Google Place Details (place_id → coordinates).
/// - Geocode / Reverse Geocode: Google Geocoding API + native fallback.
/// - Session tokens for billing optimization ($0.017/session).
/// - No country restriction (worldwide coverage).
class PlacesService {
  final String apiKey;
  PlacesService(this.apiKey);

  /// True when the key looks like a real Google API key.
  bool get isKeyValid =>
      apiKey.isNotEmpty &&
      apiKey != 'YOUR_GOOGLE_SERVICES_KEY' &&
      apiKey.startsWith('AIza');

  // ─── Session token management ──────────────────────────────────────

  static final _uuid = Uuid();
  String _sessionToken = _uuid.v4();

  /// Call after the user selects a suggestion and you call details().
  void resetSession() {
    _sessionToken = _uuid.v4();
  }

  // ─── Geocode (address → coordinates) ───────────────────────────────

  Future<PlaceDetails?> geocodeAddress(
    String address, {
    double? latitude,
    double? longitude,
  }) async {
    final clean = address.trim();
    if (clean.isEmpty) return null;

    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
        'address': clean,
        'key': apiKey,
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      final data = jsonDecode(res.body);
      if (data['status'] == 'OK') {
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final first = results.first;
          final loc = first['geometry']?['location'];
          final lat = (loc?['lat'] as num?)?.toDouble();
          final lng = (loc?['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) {
            return PlaceDetails(
              address: first['formatted_address']?.toString() ?? clean,
              lat: lat,
              lng: lng,
            );
          }
        }
      }
    } catch (_) {}

    return null;
  }

  // ─── Reverse Geocode (coordinates → address) ──────────────────────

  Future<String?> reverseGeocode({
    required double lat,
    required double lng,
  }) async {
    String? parseNative(List<geo.Placemark> placemarks) {
      if (placemarks.isEmpty) return null;
      final p = placemarks.first;
      final parts = <String>[];
      if (p.street != null && p.street!.isNotEmpty) {
        parts.add(p.street!);
      } else {
        if (p.subThoroughfare != null && p.subThoroughfare!.isNotEmpty) {
          parts.add(p.subThoroughfare!);
        }
        if (p.thoroughfare != null && p.thoroughfare!.isNotEmpty) {
          parts.add(p.thoroughfare!);
        }
      }
      if (p.locality != null && p.locality!.isNotEmpty) parts.add(p.locality!);
      if (p.administrativeArea != null && p.administrativeArea!.isNotEmpty) {
        parts.add(p.administrativeArea!);
      }
      return parts.isNotEmpty ? parts.join(', ') : null;
    }

    // Parallel: native + Google
    try {
      final both = await Future.wait([
        geo.placemarkFromCoordinates(lat, lng)
            .timeout(const Duration(seconds: 5))
            .then(parseNative)
            .catchError((_) => null),
        http.get(Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
              'latlng': '$lat,$lng',
              'key': apiKey,
            }))
            .timeout(const Duration(seconds: 5))
            .then((res) {
              final data = jsonDecode(res.body);
              if (data['status'] == 'OK') {
                final results = data['results'] as List?;
                if (results != null && results.isNotEmpty) {
                  return results.first['formatted_address']?.toString();
                }
              }
              return null;
            })
            .catchError((_) => null),
      ]);

      if (both[0] != null && (both[0] as String).isNotEmpty) {
        return both[0] as String;
      }
      if (both[1] != null && (both[1] as String).isNotEmpty) {
        return both[1] as String;
      }
    } catch (_) {}

    return null;
  }

  // ─── Autocomplete (text → list of suggestions) ────────────────────
  //
  // Google Places Autocomplete — full worldwide coverage:
  //  • No type restriction → addresses + businesses + POIs
  //  • Session tokens → cost optimization
  //  • Location bias → proximity ranking

  int _autocompleteSeq = 0;

  Future<List<PlaceSuggestion>> autocomplete(
    String input, {
    double? latitude,
    double? longitude,
  }) async {
    final cleanInput = input.trim();
    if (cleanInput.isEmpty) return [];

    if (!isKeyValid) {
      debugPrint(
        '\u26a0\ufe0f Places autocomplete: API key is empty or invalid. '
        'Set your Google API key in lib/config/env.dart (mapsServicesKey). '
        'Current key: "${apiKey.isEmpty ? "(empty)" : apiKey.substring(0, (apiKey.length).clamp(0, 8))}..."',
      );
      return [];
    }

    final seq = ++_autocompleteSeq;
    final hasLocation = latitude != null && longitude != null;

    try {
      // Run two Google requests in parallel: all types + geocode-only
      final allResults = await Future.wait([
        // [0] All types (businesses, POIs, airports, hotels, etc.)
        _googleAutocomplete(cleanInput, lat: latitude, lon: longitude)
            .catchError((_) => <PlaceSuggestion>[]),
        // [1] Geocode type (residential addresses, streets)
        _googleAutocomplete(cleanInput, lat: latitude, lon: longitude, types: 'geocode')
            .catchError((_) => <PlaceSuggestion>[]),
      ]);

      if (seq != _autocompleteSeq) return [];

      // Merge: all-types first (businesses, airports), then geocode (addresses)
      final merged = <PlaceSuggestion>[];
      merged.addAll(allResults[0]);
      merged.addAll(allResults[1]);

      // Enrich with distance if user location available
      if (hasLocation) {
        for (int i = 0; i < merged.length; i++) {
          final s = merged[i];
          if (s.lat != null && s.lng != null) {
            final dist = _haversineDistance(latitude, longitude, s.lat!, s.lng!);
            final miles = dist * 0.621371;
            merged[i] = s.copyWith(distanceMiles: miles);
          }
        }
      }

      // Geocoding fallback: if very few results, try direct geocode
      if (allResults[0].length + allResults[1].length < 3) {
        try {
          final geocoded = await _geocodeFallback(cleanInput);
          if (seq == _autocompleteSeq && geocoded.isNotEmpty) {
            merged.addAll(geocoded);
          }
        } catch (_) {}
      }

      if (merged.isEmpty) return [];
      return _dedupeByDescription(merged).take(25).toList();
    } catch (_) {
      return [];
    }
  }

  // ─── Google Places Autocomplete ────────────────────────────────────

  Future<List<PlaceSuggestion>> _googleAutocomplete(
    String input, {
    double? lat,
    double? lon,
    String? types,
  }) async {
    final params = <String, String>{
      'input': input,
      'key': apiKey,
      'sessiontoken': _sessionToken,
    };
    if (types != null && types.isNotEmpty) {
      params['types'] = types;
    }

    // Location bias: center on user, 80km radius (soft preference, not filter)
    if (lat != null && lon != null) {
      params['location'] = '$lat,$lon';
      params['radius'] = '80000';
    }

    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/place/autocomplete/json',
      params,
    );

    try {
      debugPrint('\ud83d\udd0d Places: fetching "$input"${types != null ? ' (types=$types)' : ''}');
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        debugPrint('\u274c Places HTTP ${res.statusCode}');
        return [];
      }
      final data = jsonDecode(res.body);
      final status = data['status'] as String? ?? '';

      if (status == 'REQUEST_DENIED') {
        debugPrint(
          '\u26a0\ufe0f Google Places Autocomplete: REQUEST_DENIED — '
          '${data['error_message'] ?? 'check API key restrictions'}',
        );
        return [];
      }
      if (status != 'OK' && status != 'ZERO_RESULTS') {
        debugPrint('\u26a0\ufe0f Places API status: $status');
        return [];
      }

      final predictions = data['predictions'] as List? ?? [];
      debugPrint('\u2705 Places: ${predictions.length} results for "$input"');
      return predictions
          .map<PlaceSuggestion?>((p) {
            final description = p['description']?.toString() ?? '';
            final placeId = p['place_id']?.toString() ?? '';
            if (description.isEmpty || placeId.isEmpty) return null;
            final placeTypes = List<String>.from(p['types'] as List? ?? []);
            return PlaceSuggestion(
              description: description,
              placeId: placeId,
              types: placeTypes,
            );
          })
          .whereType<PlaceSuggestion>()
          .toList();
    } catch (e) {
      debugPrint('⚠️ Google Places Autocomplete error: $e');
      return [];
    }
  }

  // ─── Place Details ─────────────────────────────────────────────────

  Future<PlaceDetails?> details(String placeId) async {
    // Handle legacy embedded-coordinate placeIds (exact:lat,lng)
    if (placeId.startsWith('exact:')) {
      final raw = placeId.substring('exact:'.length);
      final parts = raw.split(',');
      if (parts.length == 2) {
        final lat = double.tryParse(parts[0]);
        final lng = double.tryParse(parts[1]);
        if (lat != null && lng != null) {
          return PlaceDetails(address: '', lat: lat, lng: lng);
        }
      }
      return null;
    }

    // Google Place Details — include session token to bundle billing
    try {
      final uri =
          Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
            'place_id': placeId,
            'fields': 'geometry,formatted_address,name,types',
            'key': apiKey,
            'sessiontoken': _sessionToken,
          });
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      final data = jsonDecode(res.body);
      if (data['status'] == 'OK') {
        final r = data['result'];
        final loc = r['geometry']['location'];
        resetSession();
        return PlaceDetails(
          address: r['formatted_address'] ?? '',
          lat: (loc['lat'] as num).toDouble(),
          lng: (loc['lng'] as num).toDouble(),
        );
      }
    } catch (_) {}
    return null;
  }

  // ─── Geocoding Fallback (for sparse autocomplete) ──────────────────

  Future<List<PlaceSuggestion>> _geocodeFallback(String query) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'address': query,
      'key': apiKey,
    });
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      if (data['status'] != 'OK') return [];
      final results = data['results'] as List? ?? [];
      return results
          .take(5)
          .map<PlaceSuggestion?>((r) {
            final loc = r['geometry']?['location'];
            final lat = (loc?['lat'] as num?)?.toDouble();
            final lng = (loc?['lng'] as num?)?.toDouble();
            final addr = r['formatted_address']?.toString() ?? '';
            if (lat == null || lng == null || addr.isEmpty) return null;
            return PlaceSuggestion(
              description: addr,
              placeId: 'exact:$lat,$lng',
              lat: lat,
              lng: lng,
            );
          })
          .whereType<PlaceSuggestion>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  double _haversineDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .trim()
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ñ', 'n')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<PlaceSuggestion> _dedupeByDescription(List<PlaceSuggestion> input) {
    final out = <PlaceSuggestion>[];
    final seen = <String>{};
    for (final item in input) {
      final key = _normalize(item.description);
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      out.add(item);
    }
    return out;
  }
}
