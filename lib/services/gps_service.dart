import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/lat_lng.dart';

/// Singleton service that uploads driver GPS to Firebase Realtime Database
/// every 800 ms and manages online/offline presence automatically.
///
/// Does NOT own a Geolocator stream — the screen feeds positions via
/// [updatePosition] so there's only ONE system-wide GPS subscription.
class GpsService {
  static final GpsService _instance = GpsService._internal();
  factory GpsService() => _instance;
  GpsService._internal();

  final _database = FirebaseDatabase.instance;
  static const Duration _uploadInterval = Duration(seconds: 3);

  Timer? _uploadTimer;
  LatLng? _lastUploadedPos;
  LatLng? _currentPos;
  double _currentHeading = 0;
  double _currentSpeed = 0;
  String? _activeDriverId;
  String? _activeTripId;
  bool _presenceSetUp = false;
  DateTime? _lastUploadAt;
  StreamSubscription? _presenceSub;

  /// Whether the service is actively uploading.
  bool get isTracking => _uploadTimer != null;

  // Public API

  /// Begin periodic RTDB uploads and set up presence for [driverId].
  void startTracking(String driverId) {
    if (_activeDriverId == driverId && _uploadTimer != null) return;
    stopTracking();

    _activeDriverId = driverId;

    // Fallback heartbeat in case the caller pauses briefly between GPS updates.
    _uploadTimer = Timer.periodic(
      _uploadInterval,
      (_) => unawaited(_uploadToFirebase()),
    );

    _setupPresence(driverId);
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
    if (_lastUploadAt == null ||
        now.difference(_lastUploadAt!) >= const Duration(seconds: 2)) {
      unawaited(_uploadToFirebase());
    }
  }

  /// Stop uploads, mark driver offline in RTDB.
  void stopTracking() {
    _uploadTimer?.cancel();
    _uploadTimer = null;
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
    _lastUploadedPos = null;
    _lastUploadAt = null;
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
      _lastUploadedPos = null;
      _lastUploadAt = null;
    }
  }

  void dispose() {
    stopTracking();
  }

  // Private

  Future<void> _uploadToFirebase() async {
    if (_currentPos == null || _activeDriverId == null) return;
    if (_currentPos == _lastUploadedPos) return; // no change

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
      _lastUploadedPos = _currentPos;
      _lastUploadAt = DateTime.now();
    } catch (e) {
      debugPrint('GPS upload error: $e');
    }
  }

  // Presence (auto offline on disconnect)

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
}
