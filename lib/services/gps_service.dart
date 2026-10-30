import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/lat_lng.dart';
import '../config/feature_flags.dart';
import 'firebase_auth_recovery.dart';
import 'prefs_cache.dart';
import 'socket_service.dart';
import 'user_session.dart';

bool _isPermissionDenied(Object e) {
  if (e is FirebaseException) {
    return e.code == 'permission-denied';
  }
  return e.toString().contains('permission-denied');
}

/// Singleton service that uploads driver GPS via Socket.io (primary)
/// and Firebase RTDB (backup), managing online/offline presence.
///
/// Does NOT own a Geolocator stream — the screen feeds positions via
/// [updatePosition] so there's only ONE system-wide GPS subscription.
class GpsService {
  static final GpsService _instance = GpsService._internal();
  factory GpsService() => _instance;
  GpsService._internal();

  // Resolved on use (same singleton) so the position logic is testable
  // without a Firebase app.
  FirebaseDatabase get _database => FirebaseDatabase.instance;

  @visibleForTesting
  LatLng? get reportedPos => _currentPos;
  @visibleForTesting
  double get reportedHeading => _currentHeading;
  @visibleForTesting
  double get reportedSpeed => _currentSpeed;
  /// The next position goes out at once — the first fix after a stream
  /// gap (replaces re-pushing the stale pre-gap position, review 2026-10-30).
  void resetUploadThrottle() {
    _lastSocketIOAt = null;
    _lastRTDBAt = null;
  }

  @visibleForTesting
  void debugResetReported() {
    _currentPos = null;
    _currentPosAt = null;
    _trackAnchorPos = null;
    _trackAnchorAt = null;
    _currentHeading = 0;
    _currentSpeed = 0;
    _currentAccuracyM = null;
    _lastGoodFixAt = null;
  }

  // ── Intervals ───────────────────────────────────────────────────────
  // Adaptive Socket.io interval: fast (300ms) while the driver is on an
  // active trip and moving so the rider sees fluid motion; relaxed (1000ms)
  // when idle or offline to save battery/data.
  // Real-time targets: the rider's car should move as fixes land, not
  // once a second. 400 ms relaxed, 250 ms on an active trip.
  static const Duration _socketIONormalInterval = Duration(milliseconds: 400);
  static const Duration _socketIOFastInterval = Duration(milliseconds: 250);
  static const Duration _rtdbInterval = Duration(seconds: 5); // Increased from 2s
  static const double _minDistanceMeters = 2.0; // Increased from 0.5m to reduce noise

  /// Hysteresis speed thresholds for switching Socket.io cadence (m/s).
  static const double _fastSpeedOn = 1.2;
  static const double _fastSpeedOff = 0.8;

  // ── Timers ──────────────────────────────────────────────────────────
  Timer? _socketIOTimer;
  Timer? _rtdbTimer;

  // ── State ───────────────────────────────────────────────────────────
  LatLng? _currentPos;
  double _currentHeading = 0;
  double _currentSpeed = 0;
  int? _currentCapturedAtMs;
  DateTime? _currentPosAt;
  LatLng? _trackAnchorPos;
  DateTime? _trackAnchorAt;
  double? _currentAccuracyM;
  DateTime? _lastGoodFixAt;
  String? _activeDriverId;
  String? _activeTripId;
  bool _presenceSetUp = false;
  DateTime? _lastSocketIOAt;
  DateTime? _lastRTDBAt;
  LatLng? _lastSocketIOPos;
  LatLng? _lastRTDBPos;
  double _lastRTDBHeading = 0;
  bool _isFastInterval = false;
  StreamSubscription? _presenceSub;
  StreamSubscription<bool>? _socketReconnectSub;

  /// Queued position update to flush when Socket.IO reconnects.
  /// Set when Socket.IO is disconnected but we have a new position.
  LatLng? _pendingSocketIOPos;

  /// Whether the service is actively uploading.
  bool get isTracking => _socketIOTimer != null || _rtdbTimer != null;

  // ── Public API ──────────────────────────────────────────────────────

  /// Begin periodic uploads and set up presence for [driverId].
  void startTracking(String driverId) {
    if (_activeDriverId == driverId && isTracking) return;
    stopTracking();

    _activeDriverId = driverId;

    // Primary: Socket.io every 1s by default (when enabled)
    _isFastInterval = false;
    _socketIOTimer = Timer.periodic(
      _socketIONormalInterval,
      (_) => unawaited(_uploadViaSocketIO()),
    );

    // Backup: Firebase RTDB every 5 seconds
    _rtdbTimer = Timer.periodic(
      _rtdbInterval,
      (_) => unawaited(_uploadToFirebase()),
    );

    // Listen for Socket.IO reconnections to flush queued updates
    _socketReconnectSub = SocketService.connectionHealthStream.listen((connected) {
      if (connected && _pendingSocketIOPos != null) {
        debugPrint('[GPS] Socket.IO reconnected — flushing queued position');
        unawaited(_uploadViaSocketIO(force: true));
      }
    });

    unawaited(_setupPresence(driverId));
    debugPrint('[GPS] Started: Socket.io 400ms + RTDB 5s backup');
  }

  /// Attach or detach the driver's active trip context.
  void setActiveTrip(String? tripId) {
    _activeTripId = tripId == null || tripId.isEmpty ? null : tripId;
  }

  /// Feed the latest GPS fix from the screen's Geolocator stream.
  /// [capturedAt] is the fix's own `Position.timestamp` — it travels to the
  /// rider as `captured_at` so the car's glide is paced by when the fix was
  /// taken, not by when the upload throttle happened to send it.
  /// [heading] / [speed]: what the platform MEASURED, or null. Owner report
  /// 2026-10-29 ("no reportaba la ubicación exacta"): Android sends 0 for
  /// both when it has no Doppler, and those zeros went out as "stopped,
  /// facing north" — the rider's car pointed north, its animation parked
  /// and jumped, and the socket feed skipped "slow" updates of a car that
  /// was moving. Missing values are now derived from the track; a vague
  /// fix (> 50 m) right after a good one does not replace it.
  void updatePosition(LatLng pos, double? heading, double? speed,
      {DateTime? capturedAt, double? accuracyM}) {
    final arrived = DateTime.now();
    final acc = accuracyM != null && accuracyM.isFinite && accuracyM > 0
        ? accuracyM
        : null;
    if (acc != null &&
        acc > 50 &&
        _lastGoodFixAt != null &&
        arrived.difference(_lastGoodFixAt!) < const Duration(seconds: 8)) {
      return; // keep reporting the last good position
    }
    // Only a fix that DECLARES a good accuracy opens the 8 s window — a
    // re-pushed position with no accuracy opened it and the fresh fix after
    // a stream recovery was dropped (review 2026-10-30).
    if (acc != null && acc <= 25) _lastGoodFixAt = arrived;
    double? h = heading != null && heading.isFinite && heading >= 0
        ? heading % 360
        : null;
    double? v = speed != null && speed.isFinite && speed >= 0 ? speed : null;
    // Derived from a HELD anchor (review 2026-10-30): Android fixes come
    // every 0.5 s and a city-speed car does not clear the noise radius
    // between two of them — every step read 0 m/s. The anchor moves only
    // once the car has clearly moved (then speed + course) or 3 s passed
    // inside the radius (then parked); in between it is unknown (null →
    // the last value stays).
    final a = _trackAnchorPos, aAt = _trackAnchorAt;
    if (h != null && v != null) {
      _trackAnchorPos = pos;
      _trackAnchorAt = arrived;
    } else if (a == null || aAt == null) {
      _trackAnchorPos = pos;
      _trackAnchorAt = arrived;
    } else {
      final dt = arrived.difference(aAt).inMilliseconds / 1000.0;
      final d = _haversineMeters(
          a.latitude, a.longitude, pos.latitude, pos.longitude);
      // Under the fix's own error it is GPS wander, not motion.
      final minMove = max(2.0, (acc ?? 10.0) * 0.4);
      if (dt > 10) {
        _trackAnchorPos = pos;
        _trackAnchorAt = arrived;
      } else if (d >= minMove && dt >= 0.3) {
        v ??= d / dt;
        if (h == null && d >= 6) h = _bearingDeg(a, pos);
        _trackAnchorPos = pos;
        _trackAnchorAt = arrived;
      } else if (dt >= 3) {
        v ??= 0.0;
        _trackAnchorPos = pos;
        _trackAnchorAt = arrived;
      }
    }
    _currentPos = pos;
    _currentPosAt = arrived;
    _currentAccuracyM = acc;
    if (h != null) _currentHeading = h;
    if (v != null) _currentSpeed = v;
    _currentCapturedAtMs = capturedAt?.millisecondsSinceEpoch;

    // Adapt upload cadence to trip state / speed.
    _adaptSocketIOInterval(_currentSpeed);

    final now = DateTime.now();

    // Eager Socket.io upload if interval passed
    final socketInterval = _isFastInterval
        ? _socketIOFastInterval
        : _socketIONormalInterval;
    if (FeatureFlags.useSocketIO &&
        (_lastSocketIOAt == null ||
            now.difference(_lastSocketIOAt!) >= socketInterval)) {
      unawaited(_uploadViaSocketIO());
    }

    // Eager RTDB upload if interval passed
    if (_lastRTDBAt == null || now.difference(_lastRTDBAt!) >= _rtdbInterval) {
      unawaited(_uploadToFirebase());
    }
  }

  /// Switch Socket.io cadence between relaxed and fast depending on whether
  /// the driver is on an active trip and moving. Uses hysteresis to avoid
  /// toggling rapidly around the threshold.
  void _adaptSocketIOInterval(double speed) {
    final hasActiveTrip = _activeTripId != null && _activeTripId!.isNotEmpty;
    final wantsFast = hasActiveTrip && speed > _fastSpeedOn;
    final wantsNormal = !hasActiveTrip || speed < _fastSpeedOff;

    if (_isFastInterval && wantsNormal) {
      _isFastInterval = false;
      debugPrint('[GPS] Switching to relaxed Socket.io cadence (400ms)');
      _restartSocketIOTimer(_socketIONormalInterval);
    } else if (!_isFastInterval && wantsFast) {
      _isFastInterval = true;
      debugPrint('[GPS] Switching to fast Socket.io cadence (300ms) for active trip');
      _restartSocketIOTimer(_socketIOFastInterval);
    }
  }

  void _restartSocketIOTimer(Duration interval) {
    _socketIOTimer?.cancel();
    _socketIOTimer = Timer.periodic(
      interval,
      (_) => unawaited(_uploadViaSocketIO()),
    );
  }

  /// Stop uploads, mark driver offline in RTDB.
  void stopTracking() {
    _socketIOTimer?.cancel();
    _socketIOTimer = null;
    _rtdbTimer?.cancel();
    _rtdbTimer = null;
    _presenceSub?.cancel();
    _presenceSub = null;
    _socketReconnectSub?.cancel();
    _socketReconnectSub = null;

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
    _lastRTDBPos = null;
    _pendingSocketIOPos = null;
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
      if (!_isPermissionDenied(e)) {
        debugPrint('GPS clear trip location error: $e');
      }
    } finally {
      _activeTripId = null;
      _lastSocketIOAt = null;
      _lastRTDBAt = null;
      _lastSocketIOPos = null;
      _lastRTDBPos = null;
    }
  }

  void dispose() {
    stopTracking();
  }

  // ── Upload methods ──────────────────────────────────────────────────

  /// Privacy gate: when the active role is rider and the user turned off
  /// Location Sharing (`privacy_location` == false), no position upload
  /// leaves the device. Today GpsService only serves driver flows (the
  /// rider never broadcasts live location anywhere), so this is a
  /// defensive gate so any future rider-side upload honors the toggle.
  /// Local GPS use (pickup, mini map) is unaffected.
  Future<bool> _riderLocationSharingBlocked() async {
    try {
      final role = await UserSession.getMode();
      if (role != 'rider') return false;
      final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
      return !(prefs.getBool('privacy_location') ?? true);
    } catch (_) {
      return false;
    }
  }

  Future<void> _uploadViaSocketIO({bool force = false}) async {
    if (_currentPos == null || _activeDriverId == null) return;
    if (!FeatureFlags.useSocketIO) return;
    if (await _riderLocationSharingBlocked()) return;

    // If not connected, queue the latest position for flush on reconnect
    if (!SocketService.isConnected) {
      _pendingSocketIOPos = _currentPos;
      return;
    }

    // Use queued position if flushing after reconnect
    final pos = force && _pendingSocketIOPos != null ? _pendingSocketIOPos! : _currentPos!;

    // Delta compression: skip if moved < 2m AND speed is very low
    // Always send if driver is moving (speed > 1 m/s) to ensure fluid tracking
    final lastPos = force && _pendingSocketIOPos != null ? _lastSocketIOPos : _lastSocketIOPos;
    if (lastPos != null && _currentSpeed < 1.0) {
      final dist = _haversineMeters(
        pos.latitude,
        pos.longitude,
        lastPos.latitude,
        lastPos.longitude,
      );
      if (dist < _minDistanceMeters && !force) return;
    }

    final tripId = int.tryParse(_activeTripId ?? '');
    if (tripId == null) {
      // FIX: Loggear en lugar de fallar silenciosamente. Si el tripId no es
      // parseable a int, el backend debería aceptar strings. Por ahora al
      // menos loggeamos para facilitar debugging.
      debugPrint('[GPS] WARNING: activeTripId=$_activeTripId is not parseable as int — skipping Socket.io upload');
      return;
    }

    SocketService.sendDriverLocation(
      tripId: tripId,
      lat: pos.latitude,
      lng: pos.longitude,
      heading: _currentHeading,
      speed: _currentSpeed,
      capturedAtMs: _currentCapturedAtMs,
    );

    _lastSocketIOPos = pos;
    _pendingSocketIOPos = null;
    _lastSocketIOAt = DateTime.now();
  }

  Future<void> _uploadToFirebase() async {
    if (_currentPos == null || _activeDriverId == null) return;
    if (await _riderLocationSharingBlocked()) return;

    // Skip if position truly unchanged AND last upload was very recent (< 2 s).
    // This is different from _lastRTDBAt because we track the position too.
    final now = DateTime.now();
    if (_currentPos == _lastSocketIOPos &&
        _lastRTDBAt != null &&
        now.difference(_lastRTDBAt!).inMilliseconds < 2000) {
      return;
    }

    // Parked-driver gate (2026-08-25 heat fix): a driver standing still used
    // to push the same two RTDB writes every 5 s for the whole shift. Under
    // ~5 m of drift and <10° of heading change the payload is identical for
    // every practical purpose, so we only re-send once a minute as a
    // presence keepalive. A moving driver is unaffected — he keeps the
    // normal 5 s cadence.
    final lastPos = _lastRTDBPos;
    if (lastPos != null && _lastRTDBAt != null) {
      final sinceLast = now.difference(_lastRTDBAt!);
      if (sinceLast < const Duration(minutes: 1)) {
        final dist = _haversineMeters(
          _currentPos!.latitude,
          _currentPos!.longitude,
          lastPos.latitude,
          lastPos.longitude,
        );
        final headingDelta = (_currentHeading - _lastRTDBHeading).abs();
        if (dist < 5 && headingDelta < 10) return;
      }
    }
    _lastRTDBPos = _currentPos;
    _lastRTDBHeading = _currentHeading;

    final payload = {
      'lat': _currentPos!.latitude,
      'lng': _currentPos!.longitude,
      'bearing': _currentHeading,
      'heading': _currentHeading,
      'speed': _currentSpeed,
      'tripId': _activeTripId,
      'timestamp': ServerValue.timestamp,
      // Client-side capture time of the fix (ms epoch). The rider prefers
      // this over `timestamp` to pace the car's glide: server write time
      // reflects the upload cadence, not the fix spacing.
      if (_currentCapturedAtMs != null) 'captured_at': _currentCapturedAtMs,
      if (_currentAccuracyM != null) 'accuracy': _currentAccuracyM,
      'status': 'online',
    };

    if (!await _ensureAuthenticated()) return;

    try {
      await _database.ref('driver_locations/$_activeDriverId').set(payload);
      await _database.ref('drivers/$_activeDriverId/location').set(payload);
      _lastRTDBAt = now;
    } catch (e) {
      if (_isPermissionDenied(e)) {
        debugPrint('[GPS] RTDB permission denied — driver not authenticated');
      } else {
        debugPrint('GPS RTDB upload error: $e');
      }
    }
  }

  // ── Presence (auto offline on disconnect) ───────────────────────────

  /// Set up the disconnect hooks that mark the driver offline.
  ///
  /// Every call here is fire-and-forget by nature — `onDisconnect` registers
  /// an instruction with the server rather than returning a value — so each
  /// one needs its own catch. Without them a rejected write became an
  /// unhandled async error: `permission-denied` from
  /// firebase_database_platform_interface, 45 of them across 1.0.9+513 and
  /// +515 in Crashlytics, from the three lines below.
  Future<void> _setupPresence(String driverId) async {
    if (_presenceSetUp) return;
    if (!await _ensureAuthenticated()) return;
    _presenceSetUp = true;

    final connectedRef = _database.ref('.info/connected');
    _presenceSub = connectedRef.onValue.listen((event) {
      if (event.snapshot.value != true) return;

      final liveRef = _database.ref('driver_locations/$driverId');
      final legacyRef = _database.ref('drivers/$driverId/location');

      // When this client disconnects, auto-set offline.
      liveRef.onDisconnect().remove().catchError(_onPresenceError);
      legacyRef.onDisconnect().update({
        'status': 'offline',
        'timestamp': ServerValue.timestamp,
      }).catchError(_onPresenceError);
      // Set online now.
      legacyRef.update({'status': 'online'}).catchError(_onPresenceError);
    });
  }

  void _onPresenceError(Object e) {
    if (_isPermissionDenied(e)) {
      debugPrint('[GPS] presence write denied — no Firebase session');
      // The session went away after setup; let the next start rebuild it.
      _presenceSetUp = false;
      return;
    }
    debugPrint('[GPS] presence write failed: $e');
  }

  /// Guarantee a Firebase session before touching RTDB.
  ///
  /// Every path this service writes — `driver_locations/$id` and
  /// `drivers/$id/location` — is gated on `auth != null` in
  /// database.rules.json, and nothing here ever checked. The anonymous
  /// session is created at startup, but a cold start races it and a token
  /// refresh leaves a window with no user; the writes went out anyway and
  /// came back denied. This is the same defence the Firestore screens
  /// already apply, which RTDB never got.
  Future<bool> _ensureAuthenticated() async {
    // Anonymous auth is disabled on this project — the working path is the
    // backend-minted custom token, centralised in FirebaseAuthRecovery.
    return FirebaseAuthRecovery.ensureSignedIn();
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  static double _bearingDeg(LatLng a, LatLng b) {
    final la = a.latitude * pi / 180, lb = b.latitude * pi / 180;
    final dl = (b.longitude - a.longitude) * pi / 180;
    final y = sin(dl) * cos(lb);
    final x = cos(la) * sin(lb) - sin(la) * cos(lb) * cos(dl);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

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
