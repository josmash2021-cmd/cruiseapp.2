import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'api_service.dart';
import 'user_session.dart';
import 'analytics_service.dart';

/// Socket.io service for real-time communication.
///
/// Primary channel for:
///   - driver GPS updates  (driver → server → rider)
///   - trip status updates (driver/rider → server → all parties)
///
/// Firebase RTDB remains as passive backup (written to but not read from
/// when Socket.io is healthy).
///
/// Usage:
///   await SocketService.init();
///   SocketService.joinTrip(tripId);
///   SocketService.driverLocationStream.listen((data) => ...);
///   SocketService.tripStatusStream.listen((data) => ...);
class SocketService {
  static io.Socket? _socket;
  static bool _initialized = false;
  static bool _connected = false;
  static String? _currentTripRoom;

  // ── Event streams ───────────────────────────────────────────────────
  static final _driverLocationController =
      StreamController<Map<String, dynamic>>.broadcast();
  static final _tripStatusController =
      StreamController<Map<String, dynamic>>.broadcast();
  static final _driverAssignedController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of driver location updates.
  /// Payload: {trip_id, lat, lng, heading, speed, timestamp}
  static Stream<Map<String, dynamic>> get driverLocationStream =>
      _driverLocationController.stream;

  /// Stream of trip status updates.
  /// Payload: {trip_id, status, timestamp, ...}
  static Stream<Map<String, dynamic>> get tripStatusStream =>
      _tripStatusController.stream;

  /// Stream of driver assignment events.
  /// Payload: {trip_id, driver_id, ...}
  static Stream<Map<String, dynamic>> get driverAssignedStream =>
      _driverAssignedController.stream;

  // ── Public API ──────────────────────────────────────────────────────

  static bool get isConnected => _connected;
  static String? get currentTripRoom => _currentTripRoom;

  /// Initialize Socket.io connection.
  static Future<void> init() async {
    if (_initialized) return;

    final serverUrl = ApiService.activeServerUrl;
    final token = await ApiService.getToken();

    debugPrint('[Socket.io] Connecting to $serverUrl');

    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .setAuth({'token': token})
          .enableForceNew()
          .setReconnectionAttempts(10)
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(10000)
          .setTimeout(10000)
          .build(),
    );

    _socket!.onConnect((_) {
      _connected = true;
      debugPrint('[Socket.io] Connected');
      _authenticate();
      AnalyticsService.instance.logEvent('socket_connected');
    });

    _socket!.onDisconnect((_) {
      _connected = false;
      debugPrint('[Socket.io] Disconnected');
      AnalyticsService.instance.logEvent('socket_disconnected');
    });

    _socket!.onConnectError((error) {
      debugPrint('[Socket.io] Connection error: $error');
      AnalyticsService.instance.logEvent('socket_error', parameters: {'error': error.toString()});
    });

    _socket!.onReconnect((_) {
      debugPrint('[Socket.io] Reconnected — rejoining rooms');
      _authenticate();
      if (_currentTripRoom != null) {
        joinTrip(int.parse(_currentTripRoom!));
      }
    });

    // ── Event listeners ─────────────────────────────────────────────
    _socket!.on('authenticated', (data) {
      debugPrint('[Socket.io] Authenticated: $data');
    });

    _socket!.on('auth_error', (data) {
      debugPrint('[Socket.io] Auth error: $data');
    });

    _socket!.on('trip_joined', (data) {
      debugPrint('[Socket.io] Joined trip: ${data['trip_id']}');
    });

    _socket!.on('driver_location_update', (data) {
      final map = _toMap(data);
      _driverLocationController.add(map);
      _logLatency(map['timestamp'], 'driver_location');
    });

    _socket!.on('trip_status_update', (data) {
      final map = _toMap(data);
      _tripStatusController.add(map);
      _logLatency(map['timestamp'], 'trip_status');
      debugPrint('[Socket.io] Trip status: ${map['status']}');
    });

    _socket!.on('driver_assigned', (data) {
      final map = _toMap(data);
      _driverAssignedController.add(map);
      debugPrint('[Socket.io] Driver assigned: ${map['driver_id']}');
    });

    _initialized = true;
  }

  /// Authenticate with the server using JWT.
  static void _authenticate() {
    if (_socket == null || !_connected) return;

    ApiService.getToken().then((token) {
      return UserSession.getUser().then((user) {
        final userType = user?['role'] ?? 'rider';
        final userId = user?['id'];
        _socket!.emit('authenticate', {
          'token': token,
          'user_type': userType,
          'user_id': userId,
        });
      });
    }).catchError((e) {
      debugPrint('[Socket.io] Auth failed: $e');
    });
  }

  /// Join a trip room to receive real-time updates.
  static void joinTrip(int tripId) {
    if (_socket == null || !_connected) {
      debugPrint('[Socket.io] Cannot join trip — not connected');
      return;
    }
    _currentTripRoom = tripId.toString();
    _socket!.emit('join_trip', {'trip_id': tripId});
    debugPrint('[Socket.io] Joining trip room: $tripId');
  }

  /// Leave the current trip room.
  static void leaveTrip(int tripId) {
    if (_socket == null || !_connected) return;
    _socket!.emit('leave_trip', {'trip_id': tripId});
    if (_currentTripRoom == tripId.toString()) {
      _currentTripRoom = null;
    }
    debugPrint('[Socket.io] Left trip room: $tripId');
  }

  /// Send driver GPS update to the server.
  static void sendDriverLocation({
    required int tripId,
    required double lat,
    required double lng,
    double heading = 0,
    double speed = 0,
  }) {
    if (_socket == null || !_connected) return;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _socket!.emit('driver_location', {
      'trip_id': tripId,
      'lat': lat,
      'lng': lng,
      'heading': heading,
      'speed': speed,
      'timestamp': timestamp,
    });
  }

  /// Send trip status update to the server.
  static void sendTripStatus({
    required int tripId,
    required String status,
  }) {
    if (_socket == null || !_connected) return;

    _socket!.emit('trip_status', {
      'trip_id': tripId,
      'status': status,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Disconnect and clean up.
  static void dispose() {
    if (_currentTripRoom != null) {
      try {
        leaveTrip(int.parse(_currentTripRoom!));
      } catch (_) {}
    }
    _socket?.dispose();
    _socket = null;
    _initialized = false;
    _connected = false;
    _currentTripRoom = null;
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  static Map<String, dynamic> _toMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }

  static void _logLatency(dynamic timestamp, String source) {
    if (timestamp is int) {
      final latency = DateTime.now().millisecondsSinceEpoch - timestamp;
      if (latency > 0) {
        debugPrint('[Socket.io] $source latency: ${latency}ms');
        AnalyticsService.instance.logEvent('socketio_latency', parameters: {
          'latency_ms': latency,
          'source': source,
        });
      }
    }
  }
}
