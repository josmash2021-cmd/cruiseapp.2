import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/local_cache.dart';
import '../services/map_cache_service.dart';
import '../services/user_session.dart';
import '../services/api_service.dart';
import '../models/lat_lng.dart';

/// Centralized pre-loader that runs during the splash screen.
/// Everything loads in PARALLEL via Future.wait so no screen
/// has to wait for data when it opens.
class PreloadService {
  /// Where the browser build pretends to be: downtown Birmingham, AL — the
  /// market the test data sits in. Web has no usable last-known fix and the
  /// permission prompt can hang forever, so the screens get a real coordinate
  /// instead of a spinner that never resolves.
  static const double _kWebSeedLat = 33.5186;
  static const double _kWebSeedLng = -86.8104;

  PreloadService._();

  static bool _done = false;

  /// Whether pre-loading has already completed.
  static bool get isReady => _done;

  // ── Cached results available to any screen after preload ──
  static Position? initialPosition;
  static Map<String, dynamic>? cachedUserProfile;
  static Map<String, dynamic>? cachedDriverEarnings;
  static String? userMode;

  /// Run all pre-loads in parallel. Safe to call multiple times —
  /// subsequent calls return immediately.
  static Future<void> preloadAll(BuildContext? context) async {
    if (_done) return;

    await Future.wait<void>([
      _preloadGps(),
      _preloadUserData(),
      _preloadMapTiles(),
      if (context != null) _precacheImages(context),
    ]);

    _done = true;
    debugPrint('[PreloadService] all pre-loads complete');
  }

  // ── GPS: get first fix early (takes longest on cold start) ──
  static Future<void> _preloadGps() async {
    // Web: the browser DOES have real geolocation (the Geolocation API —
    // getCurrentPosition is what triggers the permission prompt there).
    // This used to skip it entirely and pretend the rider was in downtown
    // Birmingham: the home mini map and the ride-request pickup then showed
    // a confident wrong answer for anyone not actually there. Ask for the
    // real fix first; fall back to the last cached fix, then to the seed —
    // logging which path was taken instead of failing silently.
    if (kIsWeb) {
      try {
        initialPosition = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        ).timeout(const Duration(seconds: 10), onTimeout: () {
          throw TimeoutException('web GPS timeout');
        });
        debugPrint('[PreloadService] web GPS: real browser fix '
            '${initialPosition!.latitude},${initialPosition!.longitude}');
        await Future.wait([
          LocalCache.set('last_driver_lat', initialPosition!.latitude),
          LocalCache.set('last_driver_lng', initialPosition!.longitude),
        ]);
        return;
      } catch (e) {
        debugPrint('[PreloadService] web GPS unavailable ($e) — trying cache');
      }
      final lat = LocalCache.get<double>('last_driver_lat');
      final lng = LocalCache.get<double>('last_driver_lng');
      if (lat != null && lng != null) {
        debugPrint('[PreloadService] web GPS: cached fix $lat,$lng');
        initialPosition = Position(
          latitude: lat,
          longitude: lng,
          timestamp: DateTime.now(),
          accuracy: 10,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        );
        return;
      }
      debugPrint('[PreloadService] web GPS: no real or cached fix — '
          'Birmingham seed fallback');
      initialPosition = Position(
        latitude: _kWebSeedLat,
        longitude: _kWebSeedLng,
        timestamp: DateTime.now(),
        accuracy: 10,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
      return;
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }

      initialPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 6),
        ),
      ).timeout(const Duration(seconds: 7), onTimeout: () {
        throw TimeoutException('GPS timeout');
      });

      // Cache for next cold start
      if (initialPosition != null) {
        await Future.wait([
          LocalCache.set('last_driver_lat', initialPosition!.latitude),
          LocalCache.set('last_driver_lng', initialPosition!.longitude),
        ]);
      }
    } catch (e) {
      debugPrint('[PreloadService] GPS preload: $e');
      // Fall back to last cached position
      final lat = LocalCache.get<double>('last_driver_lat');
      final lng = LocalCache.get<double>('last_driver_lng');
      if (lat != null && lng != null) {
        debugPrint('[PreloadService] Using cached GPS: $lat,$lng');
      }
    }
  }

  // ── User data & profile ──
  static Future<void> _preloadUserData() async {
    try {
      userMode = await UserSession.getMode();
      cachedUserProfile = (await UserSession.getUser())
          ?.map((k, v) => MapEntry(k, v as dynamic));
    } catch (e) {
      debugPrint('[PreloadService] user data preload: $e');
    }
  }

  // ── Map tiles around user's area ──
  static Future<void> _preloadMapTiles() async {
    try {
      final lat = LocalCache.get<double>('last_driver_lat');
      final lng = LocalCache.get<double>('last_driver_lng');
      if (lat != null && lng != null) {
        await MapCacheService().precacheArea(
          regionId: 'preload_area',
          lat: lat,
          lng: lng,
          minZoom: 12,
          maxZoom: 16,
          radiusKm: 5.0,
        );
      }
    } catch (e) {
      debugPrint('[PreloadService] map preload: $e');
    }
  }

  // ── Pre-cache all car images and icons ──
  static Future<void> _precacheImages(BuildContext context) async {
    try {
      final images = [
        'assets/images/car_suv.png',
        'assets/images/car_sedan.png',
        'assets/images/car_economy.png',
        'assets/images/cruisert1.png',
        'assets/images/cruisert2.png',
        'assets/images/cruisert3.png',
        'assets/images/logoapp.png',
      ];
      await Future.wait(
        images.map((img) => precacheImage(AssetImage(img), context)
            .catchError((_) {})),
      );
    } catch (e) {
      debugPrint('[PreloadService] image precache: $e');
    }
  }
}
