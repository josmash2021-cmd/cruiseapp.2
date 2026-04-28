import 'dart:convert';
import 'dart:math' show sin, cos, sqrt, atan2, pi;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:geocoding/geocoding.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../config/mapbox_config.dart';
import 'api_service.dart';

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
        'components': 'country:us',
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
      // State + ZIP in one part: "CA 90210"
      final stateZip = <String>[];
      if (p.administrativeArea != null && p.administrativeArea!.isNotEmpty) {
        stateZip.add(p.administrativeArea!);
      }
      if (p.postalCode != null && p.postalCode!.isNotEmpty) {
        stateZip.add(p.postalCode!);
      }
      if (stateZip.isNotEmpty) {
        parts.add(stateZip.join(' '));
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

  /// Reverse geocode returning full details (address + precise coordinates).
  Future<PlaceDetails?> reverseGeocodeDetailed({
    required double lat,
    required double lng,
  }) async {
    try {
      final res = await http.get(Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
        'latlng': '$lat,$lng',
        'key': apiKey,
      })).timeout(const Duration(seconds: 5));
      final data = jsonDecode(res.body);
      if (data['status'] == 'OK') {
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final first = results.first;
          final addr = first['formatted_address']?.toString();
          final loc = first['geometry']?['location'];
          final pLat = (loc?['lat'] as num?)?.toDouble();
          final pLng = (loc?['lng'] as num?)?.toDouble();
          if (addr != null && addr.isNotEmpty && pLat != null && pLng != null) {
            return PlaceDetails(address: addr, lat: pLat, lng: pLng);
          }
        }
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

    final seq = ++_autocompleteSeq;
    final hasLocation = latitude != null && longitude != null;

    // ── Run Mapbox + SearchBox + Google + backend in parallel for comprehensive results ──
    final futures = <Future<List<PlaceSuggestion>>>[];

    // Always try Mapbox Geocoding v5 (addresses, regions)
    futures.add(
      _mapboxAutocomplete(cleanInput, lat: latitude, lon: longitude)
          .catchError((_) => <PlaceSuggestion>[]),
    );

    // Mapbox SearchBox v6 (better POI/airport/business coverage)
    futures.add(
      _mapboxSearchBox(cleanInput, lat: latitude, lon: longitude)
          .catchError((_) => <PlaceSuggestion>[]),
    );

    // Google Places (local key) + backend proxy — always try both for maximum coverage
    if (isKeyValid) {
      futures.add(
        _googleAutocomplete(cleanInput, lat: latitude, lon: longitude)
            .catchError((_) => <PlaceSuggestion>[]),
      );
      futures.add(
        _googleAutocomplete(cleanInput, lat: latitude, lon: longitude, types: 'geocode')
            .catchError((_) => <PlaceSuggestion>[]),
      );
    }
    // Always add backend proxy as well — server-side key may have better API access
    futures.add(
      _backendAutocomplete(cleanInput, lat: latitude, lon: longitude)
          .catchError((_) => <PlaceSuggestion>[]),
    );

    try {
      final allResults = await Future.wait(futures);
      if (seq != _autocompleteSeq) return [];

      final merged = <PlaceSuggestion>[];
      for (final batch in allResults) {
        merged.addAll(batch);
      }

      // Enrich with distance
      if (hasLocation) {
        for (int i = 0; i < merged.length; i++) {
          final s = merged[i];
          if (s.lat != null && s.lng != null) {
            final dist = _haversineDistance(latitude, longitude, s.lat!, s.lng!);
            merged[i] = s.copyWith(distanceMiles: dist * 0.621371);
          }
        }
      }

      // Geocode fallback if very few results — try both Google + Mapbox
      if (merged.length < 5) {
        try {
          final fallbacks = await Future.wait([
            _geocodeFallback(cleanInput).catchError((_) => <PlaceSuggestion>[]),
            _mapboxGeocodeFallback(cleanInput, lat: latitude, lon: longitude)
                .catchError((_) => <PlaceSuggestion>[]),
          ]);
          if (seq == _autocompleteSeq) {
            for (final batch in fallbacks) {
              merged.addAll(batch);
            }
          }
        } catch (_) {}
      }

      if (merged.isEmpty) return [];
      return _dedupeByDescription(merged).take(15).toList();
    } catch (_) {
      return [];
    }
  }

  // ─── Backend Proxy Autocomplete ───────────────────────────────────
  //
  // Uses the backend /places/autocomplete endpoint when local API key
  // is missing or invalid. The backend has GOOGLE_MAPS_API_KEY configured.

  Future<List<PlaceSuggestion>> _backendAutocomplete(
    String input, {
    double? lat,
    double? lon,
  }) async {
    final params = <String, String>{
      'input': input,
      'country': 'us',
    };
    if (lat != null && lon != null) {
      params['lat'] = lat.toString();
      params['lng'] = lon.toString();
    }

    final uri = Uri.parse('${ApiService.publicBaseUrl}/places/autocomplete')
        .replace(queryParameters: params);

    debugPrint('\ud83d\udd0d Backend places proxy: "$input"');
    final res = await http.get(uri, headers: {
      ...ApiService.jsonHeaders(),
      'Accept': 'application/json',
      'ngrok-skip-browser-warning': 'true',
    }).timeout(const Duration(seconds: 8));

    if (res.statusCode != 200) {
      debugPrint('\u274c Backend places proxy HTTP ${res.statusCode}: ${res.body}');
      return [];
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final predictions = data['predictions'] as List? ?? [];
    debugPrint('\u2705 Backend proxy: ${predictions.length} results for "$input"');

    return predictions.map<PlaceSuggestion>((p) {
      return PlaceSuggestion(
        description: p['description']?.toString() ?? '',
        placeId: p['place_id']?.toString() ?? '',
        types: const [],
      );
    }).where((s) => s.description.isNotEmpty).toList();
  }

  // ─── Mapbox Geocoding v5 Autocomplete ─────────────────────────────

  Future<List<PlaceSuggestion>> _mapboxAutocomplete(
    String input, {
    double? lat,
    double? lon,
  }) async {
    final token = MapboxConfig.accessToken;
    if (token.isEmpty) return [];

    final encoded = Uri.encodeComponent(input);
    final params = <String, String>{
      'access_token': token,
      'autocomplete': 'true',
      'limit': '10',
      'language': 'en,es',
      'fuzzyMatch': 'true',
      'types': 'country,region,postcode,district,place,locality,neighborhood,address,poi',
      'routing': 'true',
      'country': 'us',
    };
    if (lat != null && lon != null) {
      // proximity = soft relevance bias (nearby results ranked higher)
      // NO bbox — that was a hard filter limiting results to ~55km radius
      params['proximity'] = '$lon,$lat';
    }

    final uri = Uri.https(
      'api.mapbox.com',
      '/geocoding/v5/mapbox.places/$encoded.json',
      params,
    );

    debugPrint('\ud83d\udd0d Mapbox geocoding: "$input"');
    final res = await http.get(uri).timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      debugPrint('\u274c Mapbox geocoding HTTP ${res.statusCode}');
      return [];
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final features = data['features'] as List? ?? [];
    debugPrint('\u2705 Mapbox: ${features.length} results for "$input"');

    return features.map<PlaceSuggestion?>((f) {
      final placeName = f['place_name']?.toString() ?? '';
      final shortName = f['text']?.toString() ?? '';
      if (placeName.isEmpty) return null;
      final coords = f['geometry']?['coordinates'] as List?;
      final lng = (coords != null && coords.length >= 2)
          ? (coords[0] as num).toDouble() : null;
      final lat = (coords != null && coords.length >= 2)
          ? (coords[1] as num).toDouble() : null;
      final placeId = f['id']?.toString() ?? '';
      // Detect place types from Mapbox types array
      final rawTypes = (f['place_type'] as List?)?.cast<String>() ?? <String>[];
      final types = <String>[];
      for (final t in rawTypes) {
        if (t == 'poi') types.add('establishment');
        if (t == 'address') types.add('street_address');
        if (t == 'place') types.add('locality');
        if (t == 'region') types.add('administrative_area_level_1');
      }
      // Check properties.category for place type hints
      final category = (f['properties']?['category'] ?? '').toString().toLowerCase();
      if (category.contains('airport')) types.add('airport');
      if (category.contains('hotel') || category.contains('lodging')) types.add('lodging');
      if (category.contains('hospital') || category.contains('medical')) types.add('hospital');
      if (category.contains('school') || category.contains('university')) types.add('university');
      if (category.contains('shop') || category.contains('store') || category.contains('mall')) types.add('store');

      return PlaceSuggestion(
        description: placeName,
        placeId: lat != null && lng != null
            ? 'mapbox:$lat,$lng:$placeName'
            : placeId,
        lat: lat,
        lng: lng,
        types: types,
      );
    }).whereType<PlaceSuggestion>().toList();
  }

  // ─── Mapbox Search Box API (v6) — better POI/airport coverage ──────

  Future<List<PlaceSuggestion>> _mapboxSearchBox(
    String input, {
    double? lat,
    double? lon,
  }) async {
    final token = MapboxConfig.accessToken;
    if (token.isEmpty) return [];

    final params = <String, String>{
      'q': input,
      'access_token': token,
      'session_token': _sessionToken,
      'limit': '10',
      'language': 'en,es',
      'country': 'US',
      'types': 'poi,address,place,neighborhood,street',
    };
    if (lat != null && lon != null) {
      params['proximity'] = '$lon,$lat';
    }

    final uri = Uri.https(
      'api.mapbox.com',
      '/search/searchbox/v1/suggest',
      params,
    );

    try {
      debugPrint('\u{1F50D} Mapbox SearchBox: "$input"');
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        debugPrint('\u{274C} Mapbox SearchBox HTTP ${res.statusCode}');
        return [];
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final suggestions = data['suggestions'] as List? ?? [];
      debugPrint('\u{2705} Mapbox SearchBox: ${suggestions.length} results for "$input"');

      return suggestions.map<PlaceSuggestion?>((s) {
        final name = s['name']?.toString() ?? '';
        final fullAddr = s['full_address']?.toString() ?? s['place_formatted']?.toString() ?? '';
        final description = fullAddr.isNotEmpty ? '$name, $fullAddr' : name;
        if (name.isEmpty) return null;
        final mapboxId = s['mapbox_id']?.toString() ?? '';
        // Extract types for smart icons
        final types = <String>[];
        final poiCategory = (s['poi_category'] as List?)?.cast<String>() ?? <String>[];
        final maki = s['maki']?.toString() ?? '';
        final featureType = s['feature_type']?.toString() ?? '';
        for (final cat in poiCategory) {
          final c = cat.toLowerCase();
          if (c.contains('airport')) types.add('airport');
          if (c.contains('hotel') || c.contains('lodging')) types.add('lodging');
          if (c.contains('hospital') || c.contains('medical')) types.add('hospital');
          if (c.contains('school') || c.contains('university')) types.add('university');
          if (c.contains('shop') || c.contains('store') || c.contains('mall')) types.add('store');
        }
        if (maki.contains('airport')) types.add('airport');
        if (featureType == 'poi') types.add('establishment');
        if (featureType == 'address') types.add('street_address');

        return PlaceSuggestion(
          description: description,
          placeId: mapboxId.isNotEmpty ? 'searchbox:$mapboxId' : '',
          types: types,
        );
      }).whereType<PlaceSuggestion>().where((s) => s.placeId.isNotEmpty).toList();
    } catch (e) {
      debugPrint('\u{26A0}\u{FE0F} Mapbox SearchBox error: $e');
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
      'language': 'en',
      'components': 'country:us',
    };
    if (types != null && types.isNotEmpty) {
      params['types'] = types;
    }

    // Location bias: center on user, 160km radius (soft preference, not filter)
    if (lat != null && lon != null) {
      params['location'] = '$lat,$lon';
      params['radius'] = '160000';
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

    // Handle Mapbox placeIds (mapbox:lat,lng:address)
    if (placeId.startsWith('mapbox:')) {
      final raw = placeId.substring('mapbox:'.length);
      final firstComma = raw.indexOf(',');
      if (firstComma > 0) {
        final secondColon = raw.indexOf(':', firstComma);
        final latStr = raw.substring(0, firstComma);
        final lngStr = secondColon > 0 ? raw.substring(firstComma + 1, secondColon) : raw.substring(firstComma + 1);
        final address = secondColon > 0 ? raw.substring(secondColon + 1) : '';
        final lat = double.tryParse(latStr);
        final lng = double.tryParse(lngStr);
        if (lat != null && lng != null) {
          return PlaceDetails(address: address, lat: lat, lng: lng);
        }
      }
      return null;
    }

    // Handle Mapbox SearchBox placeIds (searchbox:mapbox_id)
    if (placeId.startsWith('searchbox:')) {
      final mapboxId = placeId.substring('searchbox:'.length);
      try {
        final token = MapboxConfig.accessToken;
        final uri = Uri.https(
          'api.mapbox.com',
          '/search/searchbox/v1/retrieve/$mapboxId',
          {
            'access_token': token,
            'session_token': _sessionToken,
          },
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final features = data['features'] as List? ?? [];
          if (features.isNotEmpty) {
            final f = features[0];
            final coords = f['geometry']?['coordinates'] as List?;
            final lng = (coords != null && coords.length >= 2)
                ? (coords[0] as num).toDouble() : null;
            final lat = (coords != null && coords.length >= 2)
                ? (coords[1] as num).toDouble() : null;
            final props = f['properties'] as Map<String, dynamic>? ?? {};
            final address = props['full_address']?.toString()
                ?? props['place_formatted']?.toString()
                ?? props['name']?.toString() ?? '';
            if (lat != null && lng != null) {
              resetSession();
              return PlaceDetails(address: address, lat: lat, lng: lng);
            }
          }
        }
      } catch (e) {
        debugPrint('\u{26A0}\u{FE0F} Mapbox SearchBox retrieve failed: $e');
      }
      return null;
    }

    // Google Place Details — include session token to bundle billing
    // If API key is invalid, use backend proxy
    if (!isKeyValid) {
      try {
        return await _backendDetails(placeId);
      } catch (e) {
        debugPrint('\u26a0\ufe0f Backend place details failed: $e');
        return null;
      }
    }

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

  // ─── Backend Proxy Place Details ───────────────────────────────────

  Future<PlaceDetails?> _backendDetails(String placeId) async {
    final uri = Uri.parse('${ApiService.publicBaseUrl}/places/details')
        .replace(queryParameters: {'place_id': placeId});

    final res = await http.get(uri, headers: {
      'Accept': 'application/json',
      'ngrok-skip-browser-warning': 'true',
    }).timeout(const Duration(seconds: 8));

    if (res.statusCode != 200) {
      debugPrint('\u274c Backend place details HTTP ${res.statusCode}');
      return null;
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final lat = data['lat'] as num?;
    final lng = data['lng'] as num?;
    if (lat == null || lng == null) return null;

    resetSession();
    return PlaceDetails(
      address: data['address']?.toString() ?? '',
      lat: lat.toDouble(),
      lng: lng.toDouble(),
    );
  }

  // ─── Geocoding Fallback (for sparse autocomplete) ──────────────────

  Future<List<PlaceSuggestion>> _geocodeFallback(String query) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'address': query,
      'key': apiKey,
      'components': 'country:us',
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

  // ─── Mapbox Geocode Fallback (no Google dependency) ────────────────

  Future<List<PlaceSuggestion>> _mapboxGeocodeFallback(
    String query, {
    double? lat,
    double? lon,
  }) async {
    final token = MapboxConfig.accessToken;
    if (token.isEmpty) return [];

    final encoded = Uri.encodeComponent(query);
    final params = <String, String>{
      'access_token': token,
      'limit': '5',
      'language': 'en',
      'country': 'us',
      'types': 'address,poi,place,locality,neighborhood,district,region',
    };
    if (lat != null && lon != null) {
      params['proximity'] = '$lon,$lat';
    }

    final uri = Uri.https(
      'api.mapbox.com',
      '/geocoding/v5/mapbox.places/$encoded.json',
      params,
    );

    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final features = data['features'] as List? ?? [];
      return features.take(5).map<PlaceSuggestion?>((f) {
        final placeName = f['place_name']?.toString() ?? '';
        if (placeName.isEmpty) return null;
        final coords = f['geometry']?['coordinates'] as List?;
        final lng = (coords != null && coords.length >= 2)
            ? (coords[0] as num).toDouble()
            : null;
        final latV = (coords != null && coords.length >= 2)
            ? (coords[1] as num).toDouble()
            : null;
        return PlaceSuggestion(
          description: placeName,
          placeId: latV != null && lng != null
              ? 'mapbox:$latV,$lng:$placeName'
              : '',
          lat: latV,
          lng: lng,
        );
      }).whereType<PlaceSuggestion>().where((s) => s.placeId.isNotEmpty).toList();
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
