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

  Timer? _uploadTimer;
  LatLng? _lastUploadedPos;
  LatLng? _currentPos;
  double _currentHeading = 0;
  double _currentSpeed = 0;
  String? _activeDriverId;
  bool _presenceSetUp = false;

  /// Whether the service is actively uploading.
  bool get isTracking => _uploadTimer != null;

  // Public API

  /// Begin periodic RTDB uploads and set up presence for [driverId].
  void startTracking(String driverId) {
    if (_activeDriverId == driverId && _uploadTimer != null) return;
    stopTracking();

    _activeDriverId = driverId;

    // Upload to Firebase every 2 s (throttled from 800 ms)
    _uploadTimer = Timer.periodic(
      const Duration(milliseconds: 2000),
      (_) => _uploadToFirebase(),
    );

    _setupPresence(driverId);
  }

  /// Feed the latest GPS fix from the screen's Geolocator stream.
  void updatePosition(LatLng pos, double heading, double speed) {
    _currentPos = pos;
    _currentHeading = heading;
    _currentSpeed = speed;
  }

  /// Stop uploads, mark driver offline in RTDB.
  void stopTracking() {
    _uploadTimer?.cancel();
    _uploadTimer = null;

    final id = _activeDriverId;
    if (id != null) {
      _database.ref('drivers/$id/location').update({
        'status': 'offline',
        'timestamp': ServerValue.timestamp,
      }).catchError((_) {});
    }
    _activeDriverId = null;
    _presenceSetUp = false;
  }

  void dispose() {
    stopTracking();
  }

  // Private

  Future<void> _uploadToFirebase() async {
    if (_currentPos == null || _activeDriverId == null) return;
    if (_currentPos == _lastUploadedPos) return; // no change

    try {
      await _database.ref('drivers/$_activeDriverId/location').set({
        'lat': _currentPos!.latitude,
        'lng': _currentPos!.longitude,
        'heading': _currentHeading,
        'speed': _currentSpeed,
        'timestamp': ServerValue.timestamp,
        'status': 'online',
      });
      _lastUploadedPos = _currentPos;
    } catch (e) {
      debugPrint('GPS upload error: $e');
    }
  }

  // Presence (auto offline on disconnect)

  void _setupPresence(String driverId) {
    if (_presenceSetUp) return;
    _presenceSetUp = true;

    final connectedRef = _database.ref('.info/connected');
    connectedRef.onValue.listen((event) {
      if (event.snapshot.value == true) {
        final locRef = _database.ref('drivers/$driverId/location');
        // When this client disconnects, auto-set offline
        locRef.onDisconnect().update({
          'status': 'offline',
          'timestamp': ServerValue.timestamp,
        });
        // Set online now
        locRef.update({'status': 'online'});
      }
    });
  }
}
