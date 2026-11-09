import 'dart:convert';
import 'dart:math' show sin, cos, sqrt, atan2, pi;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:geocoding/geocoding.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../config/mapbox_config.dart';
import 'api_service.dart';
import 'place_ranking.dart';

// ─── Place type enum for smart icons ─────────────────────────────────

/// `business` = any other named place (restaurant, gym, bank…); `home` =
/// an address.
enum PlaceType {
  airport,
  hotel,
  hospital,
  education,
  commerce,
  business,
  home,
}

// ─── Models (same interface — all screens keep working) ──────────────

class PlaceSuggestion {
  final String description;
  final String placeId;
  final double? lat;
  final double? lng;
  final double? distanceMiles;
  final String? etaText;
  final List<String> types;
  final String? mainText;
  final String? secondaryText;
  PlaceSuggestion({
    required this.description,
    required this.placeId,
    this.lat,
    this.lng,
    this.distanceMiles,
    this.etaText,
    this.types = const [],
    this.mainText,
    this.secondaryText,
  });

  PlaceSuggestion copyWith({
    String? description,
    String? placeId,
    double? lat,
    double? lng,
    double? distanceMiles,
    String? etaText,
    List<String>? types,
    String? mainText,
    String? secondaryText,
  }) {
    return PlaceSuggestion(
      description: description ?? this.description,
      placeId: placeId ?? this.placeId,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      distanceMiles: distanceMiles ?? this.distanceMiles,
      etaText: etaText ?? this.etaText,
      types: types ?? this.types,
      mainText: mainText ?? this.mainText,
      secondaryText: secondaryText ?? this.secondaryText,
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
    if (types.contains('shopping_mall') ||
        types.any((t) => t == 'store' || t.endsWith('_store'))) {
      return PlaceType.commerce;
    }
    // A named place that is none of the above — a restaurant, a gym, a
    // bank — is not an address: it gets the business mark, not the pin.
    if (types.contains('establishment') ||
        types.contains('point_of_interest') ||
        types.contains('food')) {
      return PlaceType.business;
    }
    return PlaceType.home;
  }

  /// Smart icon based on place type — the outlined set, to sit with the
  /// search page's line glyphs (place_glyph.dart).
  IconData get icon {
    switch (placeType) {
      case PlaceType.airport:
        return Icons.local_airport_outlined;
      case PlaceType.hotel:
        return Icons.hotel_outlined;
      case PlaceType.hospital:
        return Icons.local_hospital_outlined;
      case PlaceType.education:
        return Icons.school_outlined;
      case PlaceType.commerce:
        return Icons.shopping_bag_outlined;
      case PlaceType.business:
        return Icons.storefront_outlined;
      case PlaceType.home:
        return Icons.location_on_outlined;
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

    // Mapbox, when neither of the first two could answer.
    //
    // The native path is the `geocoding` plugin, which has no web
    // implementation, and the Google path needs a key this build may not
    // have — on web both come back empty and the caller was left with
    // whatever generic string it started with ("Current location").
    //
    // Mapbox is already the provider this app geocodes and routes with, so
    // there is nothing new to configure: if the token is missing this returns
    // null exactly as before.
    try {
      final token = MapboxConfig.accessToken;
      if (token.isEmpty) return null;
      final uri = Uri.https(
        'api.mapbox.com',
        '/geocoding/v5/mapbox.places/$lng,$lat.json',
        {'access_token': token, 'limit': '1', 'types': 'address,poi'},
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final feats = (jsonDecode(res.body) as Map)['features'] as List?;
        if (feats != null && feats.isNotEmpty) {
          final name = feats.first['place_name']?.toString();
          if (name != null && name.isNotEmpty) return name;
        }
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
  // One Google answer (businesses by name, airports, addresses — ranked
  // around the rider with a real distance) + Mapbox addresses, merged into
  // one row per place: the rider's own state first, another state's
  // look-alike only when they ask for it (place_ranking.dart).
  //
  // Before (owner report 2026-11-08) five sources ran at once — Mapbox x2,
  // Google x2 and the server's copy of Google — and Google's old
  // `location`+`radius` bias was all but ignored: "walmart" from Hoover, AL
  // listed Walmarts in Georgia and "3659 Lorna Rd" the same house in four
  // states.

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

    // The browser can't call Google's web service (no CORS): the web build
    // asks the server, which makes the same call.
    final localGoogle = isKeyValid && !kIsWeb;
    final stateF = hasLocation
        ? riderStateAt(latitude, longitude)
        : Future<String?>.value(null);
    final googleF = (localGoogle
            ? _googleAutocomplete(cleanInput, lat: latitude, lon: longitude)
            : _backendAutocomplete(cleanInput, lat: latitude, lon: longitude))
        .catchError((_) => <PlaceSuggestion>[]);
    final mapboxF = _mapboxAutocomplete(cleanInput, lat: latitude, lon: longitude)
        .catchError((_) => <PlaceSuggestion>[]);
    // Mapbox's POI search only stands in when Google has nothing: next to
    // Google it added a row per store counter ("Walmart Deli", "Walmart
    // Pharmacy", "Walmart Money Center"…).
    final boxF = _mapboxSearchBox(cleanInput, lat: latitude, lon: longitude)
        .catchError((_) => <PlaceSuggestion>[]);

    try {
      var google = await googleF;
      if (google.isEmpty && localGoogle && seq == _autocompleteSeq) {
        // The app's key failed (restricted, quota): the server's copy.
        google = await _backendAutocomplete(cleanInput,
                lat: latitude, lon: longitude)
            .catchError((_) => <PlaceSuggestion>[]);
      }
      final mapbox = await mapboxF;
      final box = await boxF;
      if (seq != _autocompleteSeq) return [];

      final merged = <PlaceSuggestion>[
        ...google,
        ...mapbox,
        if (google.isEmpty) ...box,
      ];

      // Distance for the rows that came with coordinates (Mapbox); Google
      // and the server send theirs already measured from the rider.
      if (hasLocation) {
        for (int i = 0; i < merged.length; i++) {
          final s = merged[i];
          if (s.distanceMiles == null && s.lat != null && s.lng != null) {
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
              for (final f in batch) {
                merged.add(hasLocation && f.lat != null && f.lng != null
                    ? f.copyWith(
                        distanceMiles: _haversineDistance(
                                latitude, longitude, f.lat!, f.lng!) *
                            0.621371)
                    : f);
              }
            }
          }
        } catch (_) {}
      }

      if (merged.isEmpty) return [];
      final riderState = await stateF;
      if (seq != _autocompleteSeq) return [];
      return rankPlacesForRider(cleanInput, dedupePlaces(merged),
              riderState: riderState)
          .take(12)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ─── The rider's state ─────────────────────────────────────────────
  //
  // Two letters ("AL") for where the rider is, from Mapbox's region layer.
  // Kept per ~5 km cell for the life of the app: every keystroke searches,
  // the state doesn't change under them.

  static final Map<String, String?> _stateCache = {};

  Future<String?> riderStateAt(double lat, double lng) async {
    final key = '${(lat * 20).round()},${(lng * 20).round()}';
    if (_stateCache.containsKey(key)) return _stateCache[key];
    final token = MapboxConfig.accessToken;
    if (token.isEmpty) return null;
    try {
      final uri = Uri.https(
        'api.mapbox.com',
        '/geocoding/v5/mapbox.places/$lng,$lat.json',
        {'access_token': token, 'limit': '1', 'types': 'region'},
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      final feats = (jsonDecode(res.body) as Map)['features'] as List?;
      final props = (feats != null && feats.isNotEmpty)
          ? feats.first['properties'] as Map?
          : null;
      final code = props?['short_code']?.toString();
      // "US-AL" → "AL"; outside the US there is no state to prefer.
      final state = (code != null && code.startsWith('US-') && code.length == 5)
          ? code.substring(3)
          : null;
      _stateCache[key] = state;
      return state;
    } catch (_) {
      return null; // not cached: a network blip retries on the next key
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
      if (!kIsWeb) 'ngrok-skip-browser-warning': 'true',
    }).timeout(const Duration(seconds: 8));

    if (res.statusCode != 200) {
      debugPrint('\u274c Backend places proxy HTTP ${res.statusCode}: ${res.body}');
      return [];
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final predictions = data['predictions'] as List? ?? [];
    debugPrint('\u2705 Backend proxy: ${predictions.length} results for "$input"');

    return predictions.map<PlaceSuggestion>((p) {
      final mainText = p['main_text']?.toString() ?? '';
      final secondaryText = withoutCountry(p['secondary_text']?.toString() ?? '');
      final meters = p['distance_meters'];
      return PlaceSuggestion(
        description: p['description']?.toString() ?? '',
        placeId: p['place_id']?.toString() ?? '',
        types: List<String>.from(p['types'] as List? ?? const []),
        mainText: mainText.isNotEmpty ? mainText : null,
        secondaryText: secondaryText.isNotEmpty ? secondaryText : null,
        distanceMiles: meters is num ? meters / 1609.344 : null,
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
      // "3659 Lorna Road" over "Hoover, Alabama 35216", the way Google's
      // rows read — an address feature carries its house number apart.
      final houseNumber = f['address']?.toString() ?? '';
      final isAddress =
          ((f['place_type'] as List?) ?? const []).contains('address');
      final title = isAddress && houseNumber.isNotEmpty && shortName.isNotEmpty
          ? '$houseNumber $shortName'
          : shortName;
      final comma = placeName.indexOf(',');
      final cityLine =
          comma > 0 ? withoutCountry(placeName.substring(comma + 1).trim()) : '';
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
        if (t == 'address') {
          // A street with no house number is a road, not a place.
          types.add(houseNumber.isEmpty ? 'route' : 'street_address');
        }
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
        mainText: title.isNotEmpty ? title : null,
        secondaryText: cityLine.isNotEmpty ? cityLine : null,
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
        if (featureType == 'street') types.add('route');

        final meters = s['distance'];
        final cityLine = withoutCountry(fullAddr);
        return PlaceSuggestion(
          description: description,
          placeId: mapboxId.isNotEmpty ? 'searchbox:$mapboxId' : '',
          types: types,
          mainText: name,
          secondaryText: cityLine.isNotEmpty ? cityLine : null,
          distanceMiles: meters is num ? meters / 1609.344 : null,
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

    // Prefer what's around the rider (a preference, not a fence: another
    // state still answers when typed) and measure every row from them.
    // `locationbias` — the old `location`+`radius` pair was all but ignored:
    // "walmart" from Hoover, AL came back with Walmarts in Georgia.
    if (lat != null && lon != null) {
      params['locationbias'] = 'circle:50000@$lat,$lon';
      params['origin'] = '$lat,$lon';
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
            // "Walmart Supercenter" over "Lakeshore Parkway, Homewood, AL":
            // the name people search by, then where it is.
            final fmt = p['structured_formatting'] as Map? ?? const {};
            final main = fmt['main_text']?.toString() ?? '';
            final secondary =
                withoutCountry(fmt['secondary_text']?.toString() ?? '');
            final meters = p['distance_meters'];
            return PlaceSuggestion(
              description: description,
              placeId: placeId,
              types: placeTypes,
              mainText: main.isNotEmpty ? main : null,
              secondaryText: secondary.isNotEmpty ? secondary : null,
              distanceMiles: meters is num ? meters / 1609.344 : null,
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

    // Google Place Details — include session token to bundle billing.
    // The server's copy when the app has no key — and always in the browser,
    // which can't call Google's web service (no CORS): a tapped Google row
    // there died with "connection error" (found 2026-11-08 driving the web
    // build through an airport booking).
    if (!isKeyValid || kIsWeb) {
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
    // The app's key failed (restricted, quota): the server's copy.
    try {
      return await _backendDetails(placeId);
    } catch (_) {
      return null;
    }
  }

  // ─── Backend Proxy Place Details ───────────────────────────────────

  Future<PlaceDetails?> _backendDetails(String placeId) async {
    final uri = Uri.parse('${ApiService.publicBaseUrl}/places/details')
        .replace(queryParameters: {'place_id': placeId});

    // Signed like every API call: /places/details sits behind the API-key
    // check, and without these headers it always answered 401 — the proxy
    // never worked.
    final res = await http.get(uri, headers: {
      ...ApiService.jsonHeaders(),
      'Accept': 'application/json',
      if (!kIsWeb) 'ngrok-skip-browser-warning': 'true',
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
}
