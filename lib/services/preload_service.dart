import 'dart:async';
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
