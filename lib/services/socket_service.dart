import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'api_service.dart';
import 'user_session.dart';
import 'analytics_service.dart';
import 'network_service.dart';

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
  static bool _connecting = false;
  static String? _currentTripRoom;

  // ── Heartbeat ───────────────────────────────────────────────────────
  static Timer? _heartbeatTimer;
  static DateTime? _lastPongTime;
  static final _connectionHealthController = StreamController<bool>.broadcast();
  static Stream<bool> get connectionHealthStream => _connectionHealthController.stream;

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
  static bool get isConnecting => _connecting;
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
          .setTransports(['websocket'])  // PRIORITY: WebSocket only (faster than polling fallback)
          .setQuery({'token': token})    // Token in query string for handshake auth
          .enableForceNew()
          .enableReconnection()
          .setReconnectionAttempts(999)  // Infinite reconnection attempts
          .setReconnectionDelay(500)     // Start at 500ms (was 1000ms)
          .setReconnectionDelayMax(5000) // Cap at 5s (was 10s)
          .setRandomizationFactor(0.3)   // Add jitter to prevent thundering herd
          .setTimeout(8000)              // 8s connection timeout (was 10s)
          .build(),
    );

    _socket!.onConnect((_) {
      _connected = true;
      _connecting = false;
      _lastPongTime = DateTime.now();
      debugPrint('[Socket.io] ✅ Connected');
      _authenticate();
      _startHeartbeat();
      AnalyticsService.instance.logEvent('socket_connected');
      if (!_connectionHealthController.isClosed) {
        _connectionHealthController.add(true);
      }
    });

    _socket!.onDisconnect((_) {
      _connected = false;
      _lastPongTime = null;
      _stopHeartbeat();
      debugPrint('[Socket.io] ❌ Disconnected');
      AnalyticsService.instance.logEvent('socket_disconnected');
      if (!_connectionHealthController.isClosed) {
        _connectionHealthController.add(false);
      }
    });

    _socket!.onConnecting((_) {
      _connecting = true;
      debugPrint('[Socket.io] ⏳ Connecting...');
    });

    _socket!.onConnectError((error) {
      _connecting = false;
      debugPrint('[Socket.io] ❌ Connection error: $error');
      AnalyticsService.instance.logEvent('socket_error', parameters: {'error': error.toString()});
    });

    _socket!.onReconnect((_) {
      debugPrint('[Socket.io] 🔄 Reconnected — rejoining rooms');
      _authenticate();
      if (_currentTripRoom != null) {
        joinTrip(int.parse(_currentTripRoom!));
      }
    });

    _socket!.onReconnectAttempt((attempt) {
      debugPrint('[Socket.io] 🔄 Reconnect attempt #$attempt');
    });

    _socket!.onReconnectError((error) {
      debugPrint('[Socket.io] ❌ Reconnect error: $error');
    });

    _socket!.onReconnectFailed((_) {
      debugPrint('[Socket.io] ❌ Reconnect failed — will retry');
    });

    // ── Heartbeat / Pong ────────────────────────────────────────────
    _socket!.on('pong', (_) {
      _lastPongTime = DateTime.now();
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

    // Listen to network recovery to proactively reconnect
    NetworkService().onlineNotifier.addListener(_onNetworkChange);

    _initialized = true;
  }

  /// Proactively reconnect when network comes back online
  static void _onNetworkChange() {
    if (NetworkService().isOnline && !_connected && !_connecting && _socket != null) {
      debugPrint('[Socket.io] 🌐 Network recovered — forcing reconnect');
      _socket!.connect();
    }
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

  /// Start heartbeat to detect stale connections
  static void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_socket == null || !_connected) return;
      // Check if we haven't received a pong in 45 seconds
      if (_lastPongTime != null &&
          DateTime.now().difference(_lastPongTime!).inSeconds > 45) {
        debugPrint('[Socket.io] 💔 Heartbeat failed — connection stale, forcing reconnect');
        _connected = false;
        _socket!.disconnect();
        Future.delayed(const Duration(milliseconds: 500), () {
          _socket?.connect();
        });
        return;
      }
      // Send ping
      _socket!.emit('ping', {'timestamp': DateTime.now().millisecondsSinceEpoch});
    });
  }

  static void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Force a reconnection (useful when app comes to foreground)
  static void reconnect() {
    if (_socket == null) {
      init();
      return;
    }
    if (_connected) {
      debugPrint('[Socket.io] Already connected');
      return;
    }
    debugPrint('[Socket.io] 🔄 Forcing reconnect');
    _socket!.connect();
  }

  /// Disconnect and clean up.
  static void dispose() {
    NetworkService().onlineNotifier.removeListener(_onNetworkChange);
    _stopHeartbeat();
    if (_currentTripRoom != null) {
      try {
        leaveTrip(int.parse(_currentTripRoom!));
      } catch (_) {}
    }
    _socket?.dispose();
    _socket = null;
    _initialized = false;
    _connected = false;
    _connecting = false;
    _currentTripRoom = null;
    _lastPongTime = null;
    // Close stream controllers to prevent memory leaks
    if (!_driverLocationController.isClosed) {
      _driverLocationController.close();
    }
    if (!_tripStatusController.isClosed) {
      _tripStatusController.close();
    }
    if (!_driverAssignedController.isClosed) {
      _driverAssignedController.close();
    }
    if (!_connectionHealthController.isClosed) {
      _connectionHealthController.close();
    }
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
