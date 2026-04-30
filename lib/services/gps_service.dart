import 'dart:async';
import 'dart:math';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/lat_lng.dart';
import '../config/feature_flags.dart';
import 'socket_service.dart';

/// Singleton service that uploads driver GPS via Socket.io (primary)
/// and Firebase RTDB (backup), managing online/offline presence.
///
/// Does NOT own a Geolocator stream — the screen feeds positions via
/// [updatePosition] so there's only ONE system-wide GPS subscription.
class GpsService {
  static final GpsService _instance = GpsService._internal();
  factory GpsService() => _instance;
  GpsService._internal();

  final _database = FirebaseDatabase.instance;

  // ── Intervals ───────────────────────────────────────────────────────
  // FIX: Increased from 200ms to 1000ms to reduce network congestion
  // and prevent battery drain. Still smooth for rider tracking.
  static const Duration _socketIOInterval = Duration(milliseconds: 1000);
  static const Duration _rtdbInterval = Duration(seconds: 5); // Increased from 2s
  static const double _minDistanceMeters = 2.0; // Increased from 0.5m to reduce noise

  // ── Timers ──────────────────────────────────────────────────────────
  Timer? _socketIOTimer;
  Timer? _rtdbTimer;

  // ── State ───────────────────────────────────────────────────────────
  LatLng? _currentPos;
  double _currentHeading = 0;
  double _currentSpeed = 0;
  String? _activeDriverId;
  String? _activeTripId;
  bool _presenceSetUp = false;
  DateTime? _lastSocketIOAt;
  DateTime? _lastRTDBAt;
  LatLng? _lastSocketIOPos;
  StreamSubscription? _presenceSub;

  /// Whether the service is actively uploading.
  bool get isTracking => _socketIOTimer != null || _rtdbTimer != null;

  // ── Public API ──────────────────────────────────────────────────────

  /// Begin periodic uploads and set up presence for [driverId].
  void startTracking(String driverId) {
    if (_activeDriverId == driverId && isTracking) return;
    stopTracking();

    _activeDriverId = driverId;

    // Primary: Socket.io every 200ms (when enabled)
    _socketIOTimer = Timer.periodic(
      _socketIOInterval,
      (_) => unawaited(_uploadViaSocketIO()),
    );

    // Backup: Firebase RTDB every 5 seconds
    _rtdbTimer = Timer.periodic(
      _rtdbInterval,
      (_) => unawaited(_uploadToFirebase()),
    );

    _setupPresence(driverId);
    debugPrint('[GPS] Started: Socket.io 1s + RTDB 5s backup');
  }

  /// Attach or detach the driver's active trip context.
  void setActiveTrip(String? tripId) {
    _activeTripId = tripId == null || tripId.isEmpty ? null : tripId;
  }

  /// Feed the latest GPS fix from the screen's Geolocator stream.
  void updatePosition(LatLng pos, double heading, double speed) {
    _currentPos = pos;
    _currentHeading = heading;
    _currentSpeed = speed;

    final now = DateTime.now();

    // Eager Socket.io upload if interval passed
    if (FeatureFlags.useSocketIO &&
        (_lastSocketIOAt == null ||
            now.difference(_lastSocketIOAt!) >= _socketIOInterval)) {
      unawaited(_uploadViaSocketIO());
    }

    // Eager RTDB upload if interval passed
    if (_lastRTDBAt == null || now.difference(_lastRTDBAt!) >= _rtdbInterval) {
      unawaited(_uploadToFirebase());
    }
  }

  /// Stop uploads, mark driver offline in RTDB.
  void stopTracking() {
    _socketIOTimer?.cancel();
    _socketIOTimer = null;
    _rtdbTimer?.cancel();
    _rtdbTimer = null;
    _presenceSub?.cancel();
    _presenceSub = null;

    final id = _activeDriverId;
    if (id != null) {
      if (_activeTripId == null) {
        _database.ref('driver_locations/$id').remove().catchError((_) {});
        _database.ref('drivers/$id/location').update({
          'status': 'offline',
          'timestamp': ServerValue.timestamp,
        }).catchError((_) {});
      }
    }
    _activeDriverId = null;
    _presenceSetUp = false;
    _lastSocketIOAt = null;
    _lastRTDBAt = null;
    _lastSocketIOPos = null;
  }

  /// Remove the active trip location from RTDB when the ride ends or cancels.
  Future<void> clearTripLocation() async {
    final id = _activeDriverId;
    if (id == null) {
      _activeTripId = null;
      return;
    }

    try {
      await _database.ref('driver_locations/$id').remove();
    } catch (e) {
      debugPrint('GPS clear trip location error: $e');
    } finally {
      _activeTripId = null;
      _lastSocketIOAt = null;
      _lastRTDBAt = null;
      _lastSocketIOPos = null;
    }
  }

  void dispose() {
    stopTracking();
  }

  // ── Upload methods ──────────────────────────────────────────────────

  Future<void> _uploadViaSocketIO() async {
    if (_currentPos == null || _activeDriverId == null) return;
    if (!FeatureFlags.useSocketIO) return;
    if (!SocketService.isConnected) return;

    // Delta compression: skip if moved < 0.5m AND speed is very low
    // Always send if driver is moving (speed > 1 m/s) to ensure fluid tracking
    if (_lastSocketIOPos != null && _currentSpeed < 1.0) {
      final dist = _haversineMeters(
        _currentPos!.latitude,
        _currentPos!.longitude,
        _lastSocketIOPos!.latitude,
        _lastSocketIOPos!.longitude,
      );
      if (dist < _minDistanceMeters) return;
    }

    final tripId = int.tryParse(_activeTripId ?? '');
    if (tripId == null) return;

    SocketService.sendDriverLocation(
      tripId: tripId,
      lat: _currentPos!.latitude,
      lng: _currentPos!.longitude,
      heading: _currentHeading,
      speed: _currentSpeed,
    );

    _lastSocketIOPos = _currentPos;
    _lastSocketIOAt = DateTime.now();
  }

  Future<void> _uploadToFirebase() async {
    if (_currentPos == null || _activeDriverId == null) return;

    // Skip if position truly unchanged AND last upload was very recent (< 2 s).
    // This is different from _lastRTDBAt because we track the position too.
    final now = DateTime.now();
    if (_currentPos == _lastSocketIOPos &&
        _lastRTDBAt != null &&
        now.difference(_lastRTDBAt!).inMilliseconds < 2000) {
      return;
    }

    final payload = {
      'lat': _currentPos!.latitude,
      'lng': _currentPos!.longitude,
      'bearing': _currentHeading,
      'heading': _currentHeading,
      'speed': _currentSpeed,
      'tripId': _activeTripId,
      'timestamp': ServerValue.timestamp,
      'status': 'online',
    };

    try {
      await _database.ref('driver_locations/$_activeDriverId').set(payload);
      await _database.ref('drivers/$_activeDriverId/location').set(payload);
      _lastRTDBAt = now;
    } catch (e) {
      debugPrint('GPS RTDB upload error: $e');
    }
  }

  // ── Presence (auto offline on disconnect) ───────────────────────────

  void _setupPresence(String driverId) {
    if (_presenceSetUp) return;
    _presenceSetUp = true;

    final connectedRef = _database.ref('.info/connected');
    _presenceSub = connectedRef.onValue.listen((event) {
      if (event.snapshot.value == true) {
        final liveRef = _database.ref('driver_locations/$driverId');
        final legacyRef = _database.ref('drivers/$driverId/location');
        // When this client disconnects, auto-set offline
        liveRef.onDisconnect().remove();
        legacyRef.onDisconnect().update({
          'status': 'offline',
          'timestamp': ServerValue.timestamp,
        });
        // Set online now
        legacyRef.update({'status': 'online'});
      }
    });
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  static double _haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const R = 6371000; // Earth radius in meters
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) *
            cos(_toRad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  static double _toRad(double deg) => deg * (pi / 180.0);
}
