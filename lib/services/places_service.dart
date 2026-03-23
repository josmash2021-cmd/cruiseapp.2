import 'dart:convert';
import 'dart:math' show sin, cos, sqrt, atan2, pi;
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../config/mapbox_config.dart';

class PlaceSuggestion {
  final String description;
  final String placeId;
  final double? lat;
  final double? lng;
  final double? distanceMiles;
  final String? etaText;
  PlaceSuggestion({
    required this.description,
    required this.placeId,
    this.lat,
    this.lng,
    this.distanceMiles,
    this.etaText,
  });

  PlaceSuggestion copyWith({
    String? description,
    String? placeId,
    double? lat,
    double? lng,
    double? distanceMiles,
    String? etaText,
  }) {
    return PlaceSuggestion(
      description: description ?? this.description,
      placeId: placeId ?? this.placeId,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      distanceMiles: distanceMiles ?? this.distanceMiles,
      etaText: etaText ?? this.etaText,
    );
  }
}

class PlaceDetails {
  final String address;
  final double lat;
  final double lng;
  PlaceDetails({required this.address, required this.lat, required this.lng});
}

/// Production-ready Places service with Uber-like autocomplete behavior.
/// Uses a sequence counter to discard stale results when the user types quickly.
///
/// Uses Google Places Autocomplete as primary provider with:
/// - No type restrictions (full address + establishment coverage)
/// - Session tokens (billing optimization — bundles keystrokes into one charge)
/// - Location bias (not restriction) for proximity ranking
/// - No country/referrer restrictions
/// - Nominatim + Photon as supplementary providers for extra coverage
class PlacesService {
  final String apiKey;
  PlacesService(this.apiKey);

  // ─── Session token management ──────────────────────────────────────
  // A session token groups autocomplete keystrokes + the final place
  // details call into a single billing session ($0.017 instead of
  // $0.00283 × N keystrokes).  Reset after user selects a result.

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

    // Google Geocoding first (most comprehensive)
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
        'address': clean,
        'key': apiKey,
        'components': 'country:US',
      });
      final res = await http.get(uri);
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

    // Nominatim fallback (free, reliable)
    final nominatim = await _geocodeWithNominatim(clean);
    if (nominatim != null) return nominatim;

    // Photon fallback
    final photon = await _geocodeWithPhoton(clean);
    if (photon != null) return photon;

    return null;
  }

  // ─── Reverse Geocode (coordinates → address) ──────────────────────

  Future<String?> reverseGeocode({
    required double lat,
    required double lng,
  }) async {
    // Run native geocoder and Google API in parallel — first good result wins.
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

    // 1) Parallel: native + Google (both fast, no dependency on each other)
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

      // Native result preferred (no network round-trip)
      if (both[0] != null && (both[0] as String).isNotEmpty) {
        debugPrint('✅ Native geocode: ${both[0]}');
        return both[0] as String;
      }
      if (both[1] != null && (both[1] as String).isNotEmpty) {
        return both[1] as String;
      }
    } catch (_) {}

    // 2) Fallback: Nominatim only (skip Photon to save a round-trip)
    try {
      final nominatim = await _reverseWithNominatim(lat: lat, lng: lng);
      if (nominatim != null && nominatim.isNotEmpty) return nominatim;
    } catch (_) {}

    return null;
  }

  // ─── Autocomplete (text → list of suggestions) ────────────────────
  //
  // Uber-like behavior:
  //  • Google Places as PRIMARY source (full address database)
  //  • No type restrictions → addresses + businesses + POIs
  //  • Session tokens → cost optimization
  //  • Location bias → proximity ranking without geographic restriction
  //  • Nominatim + Photon as SUPPLEMENTARY sources
  //  • No country restriction on Google (worldwide coverage)

  // Fix 3: sequence counter — discard results from superseded requests
  int _autocompleteSeq = 0;

  Future<List<PlaceSuggestion>> autocomplete(
    String input, {
    double? latitude,
    double? longitude,
  }) async {
    final cleanInput = input.trim();
    if (cleanInput.isEmpty) return [];

    final seq = ++_autocompleteSeq; // Capture this request's sequence number
    final hasLocation = latitude != null && longitude != null;

    try {
      // ── Run ALL providers in parallel for maximum coverage & speed ──
      final allResults = await Future.wait([
        // [0] Google Places — ALL types (businesses, POIs, airports, addresses)
        _searchWithGoogleAutocomplete(
          cleanInput,
          lat: latitude,
          lon: longitude,
        ).catchError((_) => <PlaceSuggestion>[]),
        // [1] Google Places — GEOCODE type (residential addresses, streets)
        _searchWithGoogleAutocomplete(
          cleanInput,
          lat: latitude,
          lon: longitude,
          types: 'geocode',
        ).catchError((_) => <PlaceSuggestion>[]),
        // [2] Google Places — ADDRESS type (exact street addresses, house numbers)
        _searchWithGoogleAutocomplete(
          cleanInput,
          lat: latitude,
          lon: longitude,
          types: 'address',
        ).catchError((_) => <PlaceSuggestion>[]),
        // [3] Nominatim (OSM — good for residential addresses)
        _searchWithNominatim(cleanInput).catchError((_) => <PlaceSuggestion>[]),
        // [4] Photon (OSM — proximity-biased, good for nearby addresses)
        _searchWithPhoton(
          cleanInput,
          lat: latitude,
          lon: longitude,
        ).catchError((_) => <PlaceSuggestion>[]),
        // [5] Mapbox Search Box API (full address coverage)
        _searchWithMapboxSearchBox(
          cleanInput,
          lat: latitude,
          lon: longitude,
        ).catchError((_) => <PlaceSuggestion>[]),
        // [6] Mapbox Geocoding v5 (supplementary coverage)
        _searchWithMapboxGeocoding(
          cleanInput,
          lat: latitude,
          lon: longitude,
        ).catchError((_) => <PlaceSuggestion>[]),
      ]);

      // Discard stale results
      if (seq != _autocompleteSeq) return [];

      // Merge: address-type results first (most relevant for house numbers),
      // then geocode (streets/areas), then all-types (businesses/POIs),
      // then OSM fallbacks.
      final merged = <PlaceSuggestion>[];
      merged.addAll(allResults[2]); // address (exact street addresses)
      merged.addAll(allResults[1]); // geocode (residential, streets)
      merged.addAll(allResults[0]); // all types (businesses, POIs)

      // Sort OSM + Mapbox results by proximity if location available
      final osmCandidates = <PlaceSuggestion>[];
      osmCandidates.addAll(allResults[3]); // Nominatim
      osmCandidates.addAll(allResults[4]); // Photon
      osmCandidates.addAll(allResults[5]); // Mapbox Search Box
      osmCandidates.addAll(allResults[6]); // Mapbox Geocoding v5
      if (hasLocation && osmCandidates.isNotEmpty) {
        osmCandidates.sort((a, b) {
          final aHas = a.lat != null && a.lng != null;
          final bHas = b.lat != null && b.lng != null;
          if (!aHas && !bHas) return 0;
          if (!aHas) return 1;
          if (!bHas) return -1;
          final aDist = _haversineDistance(latitude, longitude, a.lat!, a.lng!);
          final bDist = _haversineDistance(latitude, longitude, b.lat!, b.lng!);
          return aDist.compareTo(bDist);
        });
      }
      merged.addAll(osmCandidates);

      // Geocoding fallback: if Google returned few results, try direct geocode
      // to catch addresses not indexed by Places Autocomplete.
      final googleCount =
          allResults[0].length + allResults[1].length + allResults[2].length;
      if (googleCount < 3) {
        try {
          final geocoded = await _geocodeFallback(cleanInput, latitude: latitude, longitude: longitude);
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

  // ─── Google Places Autocomplete (production-ready) ─────────────────
  //
  // Configuration:
  //  • 'components=country:us' → restrict to US addresses
  //  • Session tokens → billing optimization ($0.017/session)
  //  • Location + 80km radius → proximity ranking centered on user
  //  • Optional 'types' → narrow by category (geocode, address, etc.)
  //  • No strictbounds → location is a BIAS not a restriction

  Future<List<PlaceSuggestion>> _searchWithGoogleAutocomplete(
    String input, {
    double? lat,
    double? lon,
    String? types, // e.g. 'geocode' for addresses, 'establishment' for businesses
  }) async {
    final params = <String, String>{
      'input': input,
      'key': apiKey,
      'sessiontoken': _sessionToken,
      'components': 'country:us',
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
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);

      if (data['status'] == 'REQUEST_DENIED') {
        debugPrint(
          '⚠️ Google Places Autocomplete: REQUEST_DENIED — '
          '${data['error_message'] ?? 'check API key restrictions'}',
        );
        return [];
      }
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') return [];

      final predictions = data['predictions'] as List? ?? [];
      return predictions
          .map<PlaceSuggestion?>((p) {
            final description = p['description']?.toString() ?? '';
            final placeId = p['place_id']?.toString() ?? '';
            if (description.isEmpty || placeId.isEmpty) return null;
            return PlaceSuggestion(description: description, placeId: placeId);
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
    // Handle embedded-coordinate placeIds from Nominatim/Photon/exact/Mapbox geocoding
    for (final prefix in ['exact:', 'osm:', 'photon:', 'mapbox:']) {
      if (placeId.startsWith(prefix)) {
        final raw = placeId.substring(prefix.length);
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
    }

    // Handle Mapbox Search Box suggestions (retrieve by mapbox_id)
    if (placeId.startsWith('mapbox_id:')) {
      final mapboxId = placeId.substring('mapbox_id:'.length);
      return _mapboxRetrieve(mapboxId);
    }

    // Google Place Details — include session token to bundle billing
    try {
      final uri =
          Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
            'place_id': placeId,
            'fields': 'geometry,formatted_address',
            'key': apiKey,
            'sessiontoken': _sessionToken,
          });
      final res = await http.get(uri);
      final data = jsonDecode(res.body);
      if (data['status'] == 'OK') {
        final r = data['result'];
        final loc = r['geometry']['location'];
        // Reset session after successful details fetch (end of billing session)
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

  // ─── Nominatim Search ──────────────────────────────────────────────

  Future<List<PlaceSuggestion>> _searchWithNominatim(String input) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': input,
      'format': 'jsonv2',
      'limit': '10',
      'addressdetails': '1',
      'countrycodes': 'us',
    });

    try {
      final res = await http.get(uri, headers: _nominatimHeaders());
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      if (data is! List) return [];

      return data
          .map((item) {
            final lat = double.tryParse(item['lat']?.toString() ?? '');
            final lng = double.tryParse(item['lon']?.toString() ?? '');
            if (lat == null || lng == null) return null;

            final addr = item['address'] as Map<String, dynamic>?;
            String description;
            if (addr != null) {
              description = _buildNominatimAddress(
                addr,
                fallback: item['display_name']?.toString() ?? input,
              );
            } else {
              description = item['display_name']?.toString() ?? input;
            }

            return PlaceSuggestion(
              description: description,
              placeId: 'osm:$lat,$lng',
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

  // ─── Photon Search ─────────────────────────────────────────────────

  Future<List<PlaceSuggestion>> _searchWithPhoton(
    String input, {
    double? lat,
    double? lon,
  }) async {
    final params = <String, String>{
      'q': input,
      'limit': '10',
      'lang': 'en',
      // No osm_tag filter — returns all types: addresses, streets, POIs, businesses
      'bbox': '-179.15,-14.55,-64.55,71.39',
    };
    if (lat != null && lon != null) {
      params['lat'] = '$lat';
      params['lon'] = '$lon';
    }
    final uri = Uri.https('photon.komoot.io', '/api', params);

    try {
      final res = await http.get(uri);
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final features = data['features'] as List?;
      if (features == null) return [];

      return features
          .map((item) {
            final geometry = item['geometry'];
            final coordinates = geometry?['coordinates'] as List?;
            if (coordinates == null || coordinates.length < 2) return null;

            final lng = (coordinates[0] as num?)?.toDouble();
            final lat = (coordinates[1] as num?)?.toDouble();
            if (lat == null || lng == null) return null;

            final properties = item['properties'];

            final houseNumber = properties?['housenumber']?.toString() ?? '';
            final street = properties?['street']?.toString() ?? '';
            final name = properties?['name']?.toString() ?? '';
            final city = properties?['city']?.toString() ?? '';
            final state = properties?['state']?.toString() ?? '';
            final postcode = properties?['postcode']?.toString() ?? '';

            final parts = <String>[];
            if (houseNumber.isNotEmpty && street.isNotEmpty) {
              parts.add('$houseNumber $street');
            } else if (street.isNotEmpty) {
              parts.add(street);
            } else if (name.isNotEmpty) {
              parts.add(name);
            }
            if (city.isNotEmpty) parts.add(city);
            if (state.isNotEmpty) parts.add(_abbreviateState(state));
            if (postcode.isNotEmpty) parts.add(postcode);
            final description = parts.isEmpty ? input : parts.join(', ');

            return PlaceSuggestion(
              description: description,
              placeId: 'photon:$lat,$lng',
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

  // ─── Nominatim Reverse Geocode ─────────────────────────────────────

  Future<String?> _reverseWithNominatim({
    required double lat,
    required double lng,
  }) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'lat': '$lat',
      'lon': '$lng',
      'format': 'jsonv2',
      'addressdetails': '1',
    });

    try {
      final res = await http.get(uri, headers: _nominatimHeaders());
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);

      final addr = data['address'] as Map<String, dynamic>?;
      if (addr != null) {
        final clean = _buildNominatimAddress(
          addr,
          fallback: data['display_name']?.toString(),
        );
        if (clean.isNotEmpty) return clean;
      }

      return data['display_name']?.toString();
    } catch (_) {
      return null;
    }
  }

  // ─── Nominatim Geocode ─────────────────────────────────────────────

  Future<PlaceDetails?> _geocodeWithNominatim(String input) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': input,
      'format': 'jsonv2',
      'limit': '1',
      'addressdetails': '1',
      'countrycodes': 'us',
    });

    try {
      final res = await http.get(uri, headers: _nominatimHeaders());
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is! List || data.isEmpty) return null;
      final first = data.first;
      final lat = double.tryParse(first['lat']?.toString() ?? '');
      final lng = double.tryParse(first['lon']?.toString() ?? '');
      if (lat == null || lng == null) return null;

      final addr = first['address'] as Map<String, dynamic>?;
      String address;
      if (addr != null) {
        address = _buildNominatimAddress(
          addr,
          fallback: first['display_name']?.toString() ?? input,
        );
      } else {
        address = first['display_name']?.toString() ?? input;
      }

      return PlaceDetails(address: address, lat: lat, lng: lng);
    } catch (_) {
      return null;
    }
  }

  // ─── Photon Geocode ────────────────────────────────────────────────

  Future<PlaceDetails?> _geocodeWithPhoton(String input) async {
    final uri = Uri.https('photon.komoot.io', '/api', {
      'q': input,
      'limit': '1',
      'lang': 'en',
    });

    try {
      final res = await http.get(uri);
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      final features = data['features'] as List?;
      if (features == null || features.isEmpty) return null;

      final first = features.first;
      final coordinates = first['geometry']?['coordinates'] as List?;
      if (coordinates == null || coordinates.length < 2) return null;

      final lng = (coordinates[0] as num?)?.toDouble();
      final lat = (coordinates[1] as num?)?.toDouble();
      if (lat == null || lng == null) return null;

      final props = first['properties'];
      final houseNumber = props?['housenumber']?.toString() ?? '';
      final street = props?['street']?.toString() ?? '';
      final name = props?['name']?.toString() ?? '';
      final city = props?['city']?.toString() ?? '';
      final state = props?['state']?.toString() ?? '';
      final postcode = props?['postcode']?.toString() ?? '';

      final parts = <String>[];
      if (houseNumber.isNotEmpty && street.isNotEmpty) {
        parts.add('$houseNumber $street');
      } else if (street.isNotEmpty) {
        parts.add(street);
      } else if (name.isNotEmpty) {
        parts.add(name);
      }
      if (city.isNotEmpty) parts.add(city);
      if (state.isNotEmpty) parts.add(_abbreviateState(state));
      if (postcode.isNotEmpty) parts.add(postcode);

      return PlaceDetails(
        address: parts.isEmpty ? input : parts.join(', '),
        lat: lat,
        lng: lng,
      );
    } catch (_) {
      return null;
    }
  }

  // ─── Geocoding Fallback (for sparse autocomplete) ──────────────────

  Future<List<PlaceSuggestion>> _geocodeFallback(
    String query, {
    double? latitude,
    double? longitude,
  }) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'address': query,
      'key': apiKey,
      'components': 'country:US',
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

  // ─── Mapbox Search Box API (full address coverage) ─────────────────

  String _mapboxSessionToken = _uuid.v4();

  Future<List<PlaceSuggestion>> _searchWithMapboxSearchBox(
    String input, {
    double? lat,
    double? lon,
  }) async {
    final params = <String, String>{
      'q': input,
      'country': 'US',
      'types': 'address,street,place,neighborhood,postcode',
      'language': 'en',
      'limit': '10',
      'session_token': _mapboxSessionToken,
      'access_token': MapboxConfig.accessToken,
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
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        debugPrint('⚠️ Mapbox Search Box: ${res.statusCode} ${res.body}');
        return [];
      }
      final data = jsonDecode(res.body);
      final suggestions = data['suggestions'] as List? ?? [];
      return suggestions.map<PlaceSuggestion?>((s) {
        final name = s['name']?.toString() ?? '';
        final fullAddr = s['full_address']?.toString() ?? '';
        final placeFmt = s['place_formatted']?.toString() ?? '';
        final mapboxId = s['mapbox_id']?.toString() ?? '';
        if (mapboxId.isEmpty) return null;

        final description = fullAddr.isNotEmpty
            ? fullAddr
            : (placeFmt.isNotEmpty ? '$name, $placeFmt' : name);
        if (description.isEmpty) return null;

        return PlaceSuggestion(
          description: description,
          placeId: 'mapbox_id:$mapboxId',
        );
      }).whereType<PlaceSuggestion>().toList();
    } catch (e) {
      debugPrint('⚠️ Mapbox Search Box error: $e');
      return [];
    }
  }

  // ─── Mapbox Search Box Retrieve (get coordinates from mapbox_id) ───

  Future<PlaceDetails?> _mapboxRetrieve(String mapboxId) async {
    final uri = Uri.https(
      'api.mapbox.com',
      '/search/searchbox/v1/retrieve/$mapboxId',
      {
        'session_token': _mapboxSessionToken,
        'access_token': MapboxConfig.accessToken,
      },
    );

    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      final features = data['features'] as List?;
      if (features == null || features.isEmpty) return null;

      final feature = features[0];
      final coords = feature['geometry']?['coordinates'] as List?;
      if (coords == null || coords.length < 2) return null;

      final props = feature['properties'] as Map<String, dynamic>? ?? {};
      final fullAddr = props['full_address']?.toString() ??
          props['name']?.toString() ??
          '';

      // Reset Mapbox session after retrieval (end of session)
      _mapboxSessionToken = _uuid.v4();

      return PlaceDetails(
        address: fullAddr,
        lat: (coords[1] as num).toDouble(),
        lng: (coords[0] as num).toDouble(),
      );
    } catch (e) {
      debugPrint('⚠️ Mapbox Retrieve error: $e');
      return null;
    }
  }

  // ─── Mapbox Geocoding v5 (supplementary coverage) ──────────────────

  Future<List<PlaceSuggestion>> _searchWithMapboxGeocoding(
    String input, {
    double? lat,
    double? lon,
  }) async {
    final params = <String, String>{
      'country': 'US',
      'types': 'address,place,neighborhood,postcode',
      'language': 'en',
      'limit': '5',
      'access_token': MapboxConfig.accessToken,
    };
    if (lat != null && lon != null) {
      params['proximity'] = '$lon,$lat';
    }

    final uri = Uri.https(
      'api.mapbox.com',
      '/geocoding/v5/mapbox.places/${Uri.encodeComponent(input)}.json',
      params,
    );

    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final features = data['features'] as List? ?? [];
      return features.map<PlaceSuggestion?>((f) {
        final placeName = f['place_name']?.toString() ?? '';
        final coords = f['geometry']?['coordinates'] as List?;
        if (placeName.isEmpty || coords == null || coords.length < 2) {
          return null;
        }
        final lng = (coords[0] as num).toDouble();
        final lat = (coords[1] as num).toDouble();
        return PlaceSuggestion(
          description: placeName,
          placeId: 'mapbox:$lat,$lng',
          lat: lat,
          lng: lng,
        );
      }).whereType<PlaceSuggestion>().toList();
    } catch (e) {
      debugPrint('⚠️ Mapbox Geocoding v5 error: $e');
      return [];
    }
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  String _buildNominatimAddress(Map<String, dynamic> addr, {String? fallback}) {
    final houseNumber = addr['house_number']?.toString() ?? '';
    final road = addr['road']?.toString() ?? '';
    final city =
        addr['city']?.toString() ??
        addr['town']?.toString() ??
        addr['village']?.toString() ??
        addr['hamlet']?.toString() ??
        '';
    final state = addr['state']?.toString() ?? '';
    final postcode = addr['postcode']?.toString() ?? '';

    final parts = <String>[];
    if (houseNumber.isNotEmpty && road.isNotEmpty) {
      parts.add('$houseNumber $road');
    } else if (road.isNotEmpty) {
      parts.add(road);
    }
    if (city.isNotEmpty) parts.add(city);
    if (state.isNotEmpty) parts.add(_abbreviateState(state));
    if (postcode.isNotEmpty) parts.add(postcode);

    if (parts.isNotEmpty) return parts.join(', ');
    return fallback ?? '';
  }

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

  Map<String, String> _nominatimHeaders() {
    if (kIsWeb) {
      return const {'Accept-Language': 'en'};
    }
    return const {'User-Agent': 'cruise_app/1.0', 'Accept-Language': 'en'};
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

  static String _abbreviateState(String state) {
    return _stateAbbreviations[state] ?? state;
  }

  static const _stateAbbreviations = <String, String>{
    'Alabama': 'AL',
    'Alaska': 'AK',
    'Arizona': 'AZ',
    'Arkansas': 'AR',
    'California': 'CA',
    'Colorado': 'CO',
    'Connecticut': 'CT',
    'Delaware': 'DE',
    'Florida': 'FL',
    'Georgia': 'GA',
    'Hawaii': 'HI',
    'Idaho': 'ID',
    'Illinois': 'IL',
    'Indiana': 'IN',
    'Iowa': 'IA',
    'Kansas': 'KS',
    'Kentucky': 'KY',
    'Louisiana': 'LA',
    'Maine': 'ME',
    'Maryland': 'MD',
    'Massachusetts': 'MA',
    'Michigan': 'MI',
    'Minnesota': 'MN',
    'Mississippi': 'MS',
    'Missouri': 'MO',
    'Montana': 'MT',
    'Nebraska': 'NE',
    'Nevada': 'NV',
    'New Hampshire': 'NH',
    'New Jersey': 'NJ',
    'New Mexico': 'NM',
    'New York': 'NY',
    'North Carolina': 'NC',
    'North Dakota': 'ND',
    'Ohio': 'OH',
    'Oklahoma': 'OK',
    'Oregon': 'OR',
    'Pennsylvania': 'PA',
    'Rhode Island': 'RI',
    'South Carolina': 'SC',
    'South Dakota': 'SD',
    'Tennessee': 'TN',
    'Texas': 'TX',
    'Utah': 'UT',
    'Vermont': 'VT',
    'Virginia': 'VA',
    'Washington': 'WA',
    'West Virginia': 'WV',
    'Wisconsin': 'WI',
    'Wyoming': 'WY',
    'District of Columbia': 'DC',
  };
}
