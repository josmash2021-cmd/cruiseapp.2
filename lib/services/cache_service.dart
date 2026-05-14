import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Unified persistence cache service for all critical app data.
/// Backed by SharedPreferences for sync reads on app startup.
/// Provides instant data visibility and zero-delay screen restoration.
class CacheService {
  // ══════════════════════════════════════════════════════════════
  // STATIC CACHE — Initialized in main.dart before runApp()
  // ══════════════════════════════════════════════════════════════
  
  static late SharedPreferences _prefs;
  static bool _initialized = false;

  /// Initialize cache service with SharedPreferences instance.
  /// MUST be called once in main() before any screen builds.
  static Future<void> initialize() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  // ══════════════════════════════════════════════════════════════
  // CACHE KEYS — All persistent data partitioned here
  // ══════════════════════════════════════════════════════════════

  /// User profile data (name, email, phone, etc)
  static const String _prefsKeyUser = 'cache_user_v1';

  /// Active trip ID — persist across app close/reopen
  static const String _prefsKeyActiveTripId = 'cache_active_trip_id_v1';

  /// Full trip data snapshot (route, driverLocation, ETA, status)
  static const String _prefsKeyActiveTrip = 'cache_active_trip_v1';

  /// Profile photo URL — separate key to ensure it never disappears
  static const String _prefsKeyPhotoUrl = 'cache_photo_url_v1';

  /// Driver photo URLs by driver ID (for trip details)
  static const String _prefsKeyDriverPhotoUrls = 'cache_driver_photo_urls_v1';

  /// Route coordinates from last active trip
  static const String _prefsKeyRouteCoordinates = 'cache_route_coordinates_v1';

  /// Last known driver position (lat, lng, bearing)
  static const String _prefsKeyLastDriverPosition = 'cache_last_driver_pos_v1';

  /// Last known ETA in seconds
  static const String _prefsKeyLastETA = 'cache_last_eta_v1';

  /// Driver data (name, vehicle, rating)
  static const String _prefsKeyDriver = 'cache_driver_v1';

  /// Driver online status
  static const String _prefsKeyDriverIsOnline = 'cache_driver_online_v1';

  /// User preferences (theme, language, etc)
  static const String _prefsKeyUserPreferences = 'cache_user_prefs_v1';

  // ══════════════════════════════════════════════════════════════
  // PUBLIC API — Synchronous reads, async writes
  // ══════════════════════════════════════════════════════════════

  /// Synchronously read cached user data (instant, no await)
  static Map<String, dynamic>? loadUser() {
    final prefs = _getSync();
    if (prefs == null) return null;
    final raw = prefs.getString(_prefsKeyUser);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Asynchronously save user data immediately on any update
  static Future<void> saveUser(Map<String, dynamic> userData) async {
    if (!_initialized) return;
    await _prefs.setString(_prefsKeyUser, jsonEncode(userData));
  }

  /// Synchronously load active trip ID (instant)
  static String? loadActiveTripId() {
    final prefs = _getSync();
    return prefs?.getString(_prefsKeyActiveTripId);
  }

  /// Save active trip ID — call whenever trip changes
  static Future<void> saveActiveTripId(String? tripId) async {
    if (!_initialized) return;
    if (tripId == null) {
      await _prefs.remove(_prefsKeyActiveTripId);
    } else {
      await _prefs.setString(_prefsKeyActiveTripId, tripId);
    }
  }

  /// Load full active trip data
  static Map<String, dynamic>? loadActiveTrip() {
    final prefs = _getSync();
    if (prefs == null) return null;
    final raw = prefs.getString(_prefsKeyActiveTrip);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Save full active trip data
  static Future<void> saveActiveTrip(Map<String, dynamic> tripData) async {
    if (!_initialized) return;
    await _prefs.setString(_prefsKeyActiveTrip, jsonEncode(tripData));
  }

  /// Clear active trip (call on completion/cancellation)
  static Future<void> clearActiveTrip() async {
    if (!_initialized) return;
    await _prefs.remove(_prefsKeyActiveTripId);
    await _prefs.remove(_prefsKeyActiveTrip);
    await _prefs.remove(_prefsKeyRouteCoordinates);
    await _prefs.remove(_prefsKeyLastDriverPosition);
    await _prefs.remove(_prefsKeyLastETA);
    await _prefs.remove(_prefsKeyDriver);
  }

  /// Synchronously read photo URL (instant, never blank)
  static String? loadPhotoUrl() {
    final prefs = _getSync();
    return prefs?.getString(_prefsKeyPhotoUrl);
  }

  /// Save user profile photo URL — call after upload
  static Future<void> savePhotoUrl(String url) async {
    if (!_initialized) return;
    if (url.isEmpty) {
      await _prefs.remove(_prefsKeyPhotoUrl);
    } else {
      await _prefs.setString(_prefsKeyPhotoUrl, url);
    }
  }

  /// Load all cached driver photo URLs
  static Map<String, String> loadAllDriverPhotoUrls() {
    final prefs = _getSync();
    if (prefs == null) return {};
    final raw = prefs.getString(_prefsKeyDriverPhotoUrls);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  /// Cache a driver's photo URL by driver ID
  static Future<void> saveDriverPhotoUrl(String driverId, String photoUrl) async {
    if (!_initialized) return;
    final existing = loadAllDriverPhotoUrls();
    existing[driverId] = photoUrl;
    await _prefs.setString(_prefsKeyDriverPhotoUrls, jsonEncode(existing));
  }

  /// Retrieve cached photo URL for a specific driver
  static String? loadDriverPhotoUrl(String driverId) {
    return loadAllDriverPhotoUrls()[driverId];
  }

  /// Save route coordinates (list of [lat, lng] pairs)
  static Future<void> saveRouteCoordinates(
    String tripId,
    List<List<double>> coordinates,
  ) async {
    if (!_initialized) return;
    final key = '${_prefsKeyRouteCoordinates}_$tripId';
    await _prefs.setString(key, jsonEncode(coordinates));
  }

  /// Load cached route coordinates for a trip
  static List<List<double>>? loadRouteCoordinates(String tripId) {
    final prefs = _getSync();
    if (prefs == null) return null;
    final key = '${_prefsKeyRouteCoordinates}_$tripId';
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final result = <List<double>>[];
      for (final item in decoded) {
        if (item is! List) continue;
        final coords = <double>[];
        for (final v in item) {
          if (v is num) coords.add(v.toDouble());
        }
        if (coords.length >= 2) result.add(coords);
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  /// Save last known driver position
  static Future<void> saveLastDriverPosition({
    required double lat,
    required double lng,
    required double bearing,
  }) async {
    if (!_initialized) return;
    await _prefs.setString(
      _prefsKeyLastDriverPosition,
      jsonEncode({'lat': lat, 'lng': lng, 'bearing': bearing}),
    );
  }

  /// Load last known driver position
  static Map<String, double>? loadLastDriverPosition() {
    final prefs = _getSync();
    if (prefs == null) return null;
    final raw = prefs.getString(_prefsKeyLastDriverPosition);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final result = <String, double>{};
      decoded.forEach((k, v) {
        if (v is num) result[k.toString()] = v.toDouble();
      });
      return result.isEmpty ? null : result;
    } catch (_) {
      return null;
    }
  }

  /// Save last known ETA in seconds
  static Future<void> saveLastETA(int etaSeconds) async {
    if (!_initialized) return;
    await _prefs.setInt(_prefsKeyLastETA, etaSeconds);
  }

  /// Load last known ETA
  static int? loadLastETA() {
    final prefs = _getSync();
    return prefs?.getInt(_prefsKeyLastETA);
  }

  /// Save driver info
  static Future<void> saveDriver(Map<String, dynamic> driverData) async {
    if (!_initialized) return;
    await _prefs.setString(_prefsKeyDriver, jsonEncode(driverData));
  }

  /// Load cached driver info
  static Map<String, dynamic>? loadDriver() {
    final prefs = _getSync();
    if (prefs == null) return null;
    final raw = prefs.getString(_prefsKeyDriver);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Save driver online status
  static Future<void> saveDriverIsOnline(bool isOnline) async {
    if (!_initialized) return;
    await _prefs.setBool(_prefsKeyDriverIsOnline, isOnline);
  }

  /// Load driver online status
  static bool? loadDriverIsOnline() {
    final prefs = _getSync();
    return prefs?.getBool(_prefsKeyDriverIsOnline);
  }

  /// Save user preferences
  static Future<void> saveUserPreferences(
    Map<String, dynamic> preferences,
  ) async {
    if (!_initialized) return;
    await _prefs.setString(_prefsKeyUserPreferences, jsonEncode(preferences));
  }

  /// Load user preferences
  static Map<String, dynamic>? loadUserPreferences() {
    final prefs = _getSync();
    if (prefs == null) return null;
    final raw = prefs.getString(_prefsKeyUserPreferences);
    if (raw == null || raw.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  /// Clear ALL cached data (for logout or reset)
  static Future<void> clearAll() async {
    if (!_initialized) return;
    // Keep keys in this list to clear
    final keysToRemove = [
      _prefsKeyUser,
      _prefsKeyActiveTripId,
      _prefsKeyActiveTrip,
      _prefsKeyDriver,
      _prefsKeyDriverIsOnline,
      _prefsKeyLastDriverPosition,
      _prefsKeyLastETA,
      _prefsKeyUserPreferences,
    ];
    for (final key in keysToRemove) {
      await _prefs.remove(key);
    }
    // Note: photo URLs and route coordinates can be cleared on logout
    // Policy: keep them if user logs back in quickly for convenience
  }

  // ══════════════════════════════════════════════════════════════
  // PRIVATE — Helper for sync access to prefs
  // ══════════════════════════════════════════════════════════════

  /// Get SharedPreferences synchronously (must be initialized first).
  static SharedPreferences? _getSync() {
    if (!_initialized) return null;
    return _prefs;
  }
}
