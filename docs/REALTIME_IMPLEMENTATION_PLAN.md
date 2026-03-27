# Real-Time Optimization Implementation Plan
**Target:** <200ms GPS updates, <800ms cold start, <1s login  
**Strategy:** Socket.io-first with Firebase backup  
**Timeline:** 2-3 weeks

---

## Phase 2: Performance Profiling & Bottleneck Identification (1-2 days)

### 2.1 Measure App Cold Start Latency

**Tool:** Flutter DevTools Timeline + Performance Overlay

**Steps:**
1. Enable performance overlay in app:
```dart
// lib/main.dart - add to MaterialApp
MaterialApp(
  showPerformanceOverlay: true,  // Shows 60fps graphs
  // ...
)
```

2. Profile cold start with Timeline:
```bash
# Connect device/emulator
flutter run --profile
# Open DevTools Timeline
# Record timeline during app launch
# Identify slow frames (>16ms = dropped frame)
```

3. Add custom performance markers:
```dart
// lib/main.dart - measure initialization
void main() async {
  final stopwatch = Stopwatch()..start();
  
  WidgetsFlutterBinding.ensureInitialized();
  print('[Perf] Flutter binding: ${stopwatch.elapsedMilliseconds}ms');
  
  await SecurityService.init();
  print('[Perf] SecurityService: ${stopwatch.elapsedMilliseconds}ms');
  
  await Firebase.initializeApp();
  print('[Perf] Firebase init: ${stopwatch.elapsedMilliseconds}ms');
  
  await ApiService.init();
  print('[Perf] ApiService init: ${stopwatch.elapsedMilliseconds}ms');
  
  runApp(CruiseApp());
  print('[Perf] runApp called: ${stopwatch.elapsedMilliseconds}ms');
}
```

**Success Criteria:**
- Identify slowest initialization step (likely Firebase.initializeApp)
- Measure time to first interactive frame
- Document baseline metrics

### 2.2 Measure GPS Update Latency (Driver → Rider)

**Method:** Add timestamps to GPS payloads

**Changes Required:**

**Driver Side:** `lib/services/gps_service.dart`
```dart
Future<void> _uploadLocation() async {
  if (_lastPosition == null) return;
  
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  
  await _locRef!.set({
    'lat': _lastPosition!.latitude,
    'lng': _lastPosition!.longitude,
    'heading': _lastPosition!.heading,
    'speed': _lastPosition!.speed,
    'timestamp': timestamp,  // ✅ Add client timestamp
    'updatedAt': ServerValue.timestamp,  // ✅ Add server timestamp
  });
  
  debugPrint('[GPS] Upload latency: Driver sent at $timestamp');
}
```

**Rider Side:** `lib/controllers/rider_tracking_controller.dart`
```dart
void _onRealDriverLocation(LatLng ll, int driverTimestamp) {
  final riderReceived = DateTime.now().millisecondsSinceEpoch;
  final latency = riderReceived - driverTimestamp;
  
  debugPrint('[GPS] Latency: ${latency}ms (driver sent → rider received)');
  
  // ✅ Log to Firebase Analytics for monitoring
  AnalyticsService.logEvent('gps_latency', {
    'latency_ms': latency,
    'trip_id': widget.tripId.toString(),
  });
  
  // ... existing code
}
```

**Success Criteria:**
- Measure real GPS latency over 100 updates
- Calculate average, p50, p95, p99 latencies
- Confirm 2,300-2,500ms baseline

### 2.3 Measure Login Flow Latency

**Add instrumentation to** `lib/services/user_session.dart`:
```dart
static Future<bool> isLoggedIn() async {
  final stopwatch = Stopwatch()..start();
  
  final token = await getAuthToken();
  print('[Login] Token fetch: ${stopwatch.elapsedMilliseconds}ms');
  
  if (token == null || token.isEmpty) return false;
  
  try {
    final profile = await ApiService.getProfile();
    print('[Login] Profile fetch: ${stopwatch.elapsedMilliseconds}ms');
    return profile != null;
  } catch (e) {
    print('[Login] Failed after ${stopwatch.elapsedMilliseconds}ms: $e');
    return false;
  }
}
```

**Success Criteria:**
- Identify if `getProfile()` blocks UI rendering
- Measure login flow from tap → home screen
- Document baseline metrics

### 2.4 Memory Leak Detection

**Check subscription cleanup in all screens:**
```dart
// Pattern to search for in all files
// ✅ GOOD:
@override
void dispose() {
  _subscription?.cancel();
  _timer?.cancel();
  super.dispose();
}

// ❌ BAD (missing cleanup):
@override
void dispose() {
  super.dispose();  // Forgot to cancel subscriptions!
}
```

**Automated Check:**
```bash
# Search for StreamSubscription without cancel()
rg "StreamSubscription" -A 20 --no-heading | rg -v "cancel()"

# Search for Timer without cancel()
rg "Timer\s*_\w+" -A 20 --no-heading | rg -v "cancel()"
```

**Manual Audit Files:**
- `lib/controllers/rider_tracking_controller.dart`
- `lib/screens/rider_tracking_screen.dart`
- `lib/screens/map_screen.dart`
- `lib/screens/driver_home_screen.dart`
- All files with `Timer.periodic` or `.listen()`

**Success Criteria:**
- Document all subscriptions and their cleanup
- Fix any missing `cancel()` calls
- Run memory profiler to confirm no leaks

---

## Phase 3: Socket.io Infrastructure (3-5 days)

### 3.1 Backend Socket.io Setup

**Install Dependencies:**
```bash
cd backend
pip install python-socketio==5.11.0 aiohttp==3.9.1
pip freeze > requirements.txt
```

**Create Socket.io Server:** `backend/services/socketio_service.py`
```python
"""Socket.io server for real-time communication."""
import socketio
import logging
from typing import Dict, Set

logger = logging.getLogger(__name__)

# Create Socket.io server with Redis for multi-worker support
sio = socketio.AsyncServer(
    async_mode='asgi',
    cors_allowed_origins='*',  # TODO: Restrict in production
    logger=True,
    engineio_logger=True,
)

# Track active connections
active_connections: Dict[str, Set[str]] = {
    'drivers': set(),
    'riders': set(),
    'dispatch': set(),
}

@sio.event
async def connect(sid: str, environ, auth):
    """Client connected."""
    logger.info(f'[Socket.io] Client connected: {sid}')
    return True

@sio.event
async def disconnect(sid: str):
    """Client disconnected."""
    logger.info(f'[Socket.io] Client disconnected: {sid}')
    # Remove from all rooms
    for room_type in active_connections:
        active_connections[room_type].discard(sid)

@sio.event
async def authenticate(sid: str, data: dict):
    """Authenticate client and join appropriate rooms."""
    token = data.get('token')
    user_type = data.get('user_type')  # 'driver', 'rider', 'dispatch'
    
    # TODO: Verify JWT token here
    # user = verify_jwt(token)
    # if not user:
    #     await sio.disconnect(sid)
    #     return
    
    # Join user-specific room
    user_id = data.get('user_id')
    await sio.enter_room(sid, f'{user_type}:{user_id}')
    active_connections[f'{user_type}s'].add(sid)
    
    logger.info(f'[Socket.io] {user_type} {user_id} authenticated')
    await sio.emit('authenticated', {'status': 'success'}, to=sid)

@sio.event
async def join_trip(sid: str, trip_id: int):
    """Join a trip room for real-time updates."""
    await sio.enter_room(sid, f'trip:{trip_id}')
    logger.info(f'[Socket.io] Client {sid} joined trip:{trip_id}')
    await sio.emit('trip_joined', {'trip_id': trip_id}, to=sid)

@sio.event
async def leave_trip(sid: str, trip_id: int):
    """Leave a trip room."""
    await sio.leave_room(sid, f'trip:{trip_id}')
    logger.info(f'[Socket.io] Client {sid} left trip:{trip_id}')

@sio.event
async def driver_location(sid: str, data: dict):
    """
    Receive driver GPS update and broadcast to trip room.
    
    Expected payload:
    {
      "trip_id": 123,
      "lat": 34.0522,
      "lng": -118.2437,
      "heading": 90.5,
      "speed": 15.3,
      "timestamp": 1704067200000
    }
    """
    trip_id = data.get('trip_id')
    if not trip_id:
        return
    
    # Broadcast to all clients in the trip room
    await sio.emit(
        'driver_location_update',
        {
            'lat': data['lat'],
            'lng': data['lng'],
            'heading': data.get('heading', 0),
            'speed': data.get('speed', 0),
            'timestamp': data['timestamp'],
        },
        room=f'trip:{trip_id}',
        skip_sid=sid,  # Don't send back to sender
    )

@sio.event
async def trip_status(sid: str, data: dict):
    """
    Receive trip status update and broadcast to trip room.
    
    Expected payload:
    {
      "trip_id": 123,
      "status": "arrived",
      "timestamp": 1704067200000
    }
    """
    trip_id = data.get('trip_id')
    status = data.get('status')
    
    await sio.emit(
        'trip_status_update',
        {
            'trip_id': trip_id,
            'status': status,
            'timestamp': data['timestamp'],
        },
        room=f'trip:{trip_id}',
    )
    
    logger.info(f'[Socket.io] Trip {trip_id} status: {status}')

# ── Helper functions for emitting from backend routes ──

async def emit_driver_location(trip_id: int, lat: float, lng: float, 
                                heading: float = 0, speed: float = 0):
    """Emit driver location update to trip room (called from backend routes)."""
    await sio.emit(
        'driver_location_update',
        {
            'lat': lat,
            'lng': lng,
            'heading': heading,
            'speed': speed,
            'timestamp': int(time.time() * 1000),
        },
        room=f'trip:{trip_id}',
    )

async def emit_trip_status(trip_id: int, status: str, extra: dict = None):
    """Emit trip status update to trip room."""
    payload = {
        'trip_id': trip_id,
        'status': status,
        'timestamp': int(time.time() * 1000),
    }
    if extra:
        payload.update(extra)
    
    await sio.emit('trip_status_update', payload, room=f'trip:{trip_id}')

async def notify_rider(rider_id: int, event: str, data: dict):
    """Send notification to specific rider."""
    await sio.emit(event, data, room=f'rider:{rider_id}')

async def notify_driver(driver_id: int, event: str, data: dict):
    """Send notification to specific driver."""
    await sio.emit(event, data, room=f'driver:{driver_id}')
```

**Integrate Socket.io into FastAPI:** `backend/main.py`
```python
# Add imports at top
from services.socketio_service import sio
import socketio

# Add Socket.io ASGI app
socket_app = socketio.ASGIApp(sio, other_asgi_app=app)

# Change the final app export
# OLD: app = FastAPI(...)
# NEW:
app = FastAPI(...)  # existing app setup

# Wrap app with Socket.io
socket_app = socketio.ASGIApp(
    socketio_server=sio,
    other_asgi_app=app,
    socketio_path='/socket.io',
)

# At bottom of file, change uvicorn run:
if __name__ == '__main__':
    import uvicorn
    uvicorn.run(
        'main:socket_app',  # ✅ Run wrapped app
        host='0.0.0.0',
        port=int(os.getenv('PORT', 8000)),
        reload=False,
    )
```

### 3.2 Flutter Socket.io Client Setup

**Add Dependencies:** `pubspec.yaml`
```yaml
dependencies:
  socket_io_client: ^2.0.3+1
```

**Create Socket Service:** `lib/services/socket_service.dart`
```dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'api_service.dart';
import 'user_session.dart';
import 'analytics_service.dart';

/// Socket.io service for real-time communication.
/// Replaces Firebase RTDB for driver GPS and trip status updates.
class SocketService {
  static io.Socket? _socket;
  static bool _initialized = false;
  static bool _connected = false;
  static String? _currentTripRoom;
  
  // Event streams
  static final _driverLocationController = StreamController<Map<String, dynamic>>.broadcast();
  static final _tripStatusController = StreamController<Map<String, dynamic>>.broadcast();
  
  /// Stream of driver location updates (lat, lng, heading, speed, timestamp)
  static Stream<Map<String, dynamic>> get driverLocationStream => _driverLocationController.stream;
  
  /// Stream of trip status updates (trip_id, status, timestamp)
  static Stream<Map<String, dynamic>> get tripStatusStream => _tripStatusController.stream;
  
  /// Initialize Socket.io connection to backend
  static Future<void> init() async {
    if (_initialized) return;
    
    final serverUrl = ApiService.activeServerUrl;
    final token = await UserSession.getAuthToken();
    
    debugPrint('[Socket.io] Connecting to $serverUrl');
    
    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])  // Prefer WebSocket over polling
          .setAuth({'token': token})
          .enableForceNew()
          .setReconnectionAttempts(5)
          .setReconnectionDelay(2000)
          .setReconnectionDelayMax(10000)
          .setTimeout(5000)
          .build(),
    );
    
    _socket!.onConnect((_) {
      _connected = true;
      debugPrint('[Socket.io] Connected!');
      _authenticate();
      
      AnalyticsService.logEvent('socket_connected', {});
    });
    
    _socket!.onDisconnect((_) {
      _connected = false;
      debugPrint('[Socket.io] Disconnected');
      AnalyticsService.logEvent('socket_disconnected', {});
    });
    
    _socket!.onConnectError((error) {
      debugPrint('[Socket.io] Connection error: $error');
      AnalyticsService.logEvent('socket_error', {'error': error.toString()});
    });
    
    _socket!.onReconnect((_) {
      debugPrint('[Socket.io] Reconnected - rejoining trip room');
      if (_currentTripRoom != null) {
        joinTrip(int.parse(_currentTripRoom!));
      }
    });
    
    // ── Listen for driver location updates ──
    _socket!.on('driver_location_update', (data) {
      final map = Map<String, dynamic>.from(data);
      _driverLocationController.add(map);
      
      // Log latency
      final driverTimestamp = map['timestamp'] as int?;
      if (driverTimestamp != null) {
        final latency = DateTime.now().millisecondsSinceEpoch - driverTimestamp;
        debugPrint('[Socket.io] GPS latency: ${latency}ms');
      }
    });
    
    // ── Listen for trip status updates ──
    _socket!.on('trip_status_update', (data) {
      final map = Map<String, dynamic>.from(data);
      _tripStatusController.add(map);
      debugPrint('[Socket.io] Trip status: ${map['status']}');
    });
    
    // ── Listen for authentication confirmation ──
    _socket!.on('authenticated', (data) {
      debugPrint('[Socket.io] Authenticated: $data');
    });
    
    // ── Listen for trip join confirmation ──
    _socket!.on('trip_joined', (data) {
      debugPrint('[Socket.io] Joined trip: ${data['trip_id']}');
    });
    
    _initialized = true;
  }
  
  /// Authenticate with backend (send JWT + user type)
  static Future<void> _authenticate() async {
    if (_socket == null) return;
    
    final token = await UserSession.getAuthToken();
    final user = await UserSession.getUser();
    final userType = user?['role'] ?? 'rider';  // 'driver', 'rider', 'dispatch'
    final userId = user?['id'];
    
    _socket!.emit('authenticate', {
      'token': token,
      'user_type': userType,
      'user_id': userId,
    });
  }
  
  /// Join a trip room to receive real-time updates
  static void joinTrip(int tripId) {
    if (_socket == null || !_connected) {
      debugPrint('[Socket.io] Cannot join trip - not connected');
      return;
    }
    
    _currentTripRoom = tripId.toString();
    _socket!.emit('join_trip', tripId);
    debugPrint('[Socket.io] Joining trip room: $tripId');
  }
  
  /// Leave the current trip room
  static void leaveTrip(int tripId) {
    if (_socket == null || !_connected) return;
    
    _socket!.emit('leave_trip', tripId);
    _currentTripRoom = null;
    debugPrint('[Socket.io] Left trip room: $tripId');
  }
  
  /// Send driver GPS update to server
  static void sendDriverLocation({
    required int tripId,
    required double lat,
    required double lng,
    double heading = 0,
    double speed = 0,
  }) {
    if (_socket == null || !_connected) {
      debugPrint('[Socket.io] Cannot send location - not connected');
      return;
    }
    
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
  
  /// Disconnect from Socket.io server
  static void dispose() {
    _socket?.dispose();
    _socket = null;
    _initialized = false;
    _connected = false;
    _currentTripRoom = null;
    _driverLocationController.close();
    _tripStatusController.close();
  }
  
  /// Check if connected
  static bool get isConnected => _connected;
}
```

### 3.3 Test Socket.io Connection

**Add test endpoint in main.dart:**
```dart
// lib/main.dart - after Firebase init
void main() async {
  // ... existing init code
  
  // Initialize Socket.io
  await SocketService.init();
  
  runApp(CruiseApp());
}
```

**Success Criteria:**
- Backend starts without errors
- Flutter client connects to `/socket.io`
- Authentication event received
- No connection drops over 5 minutes

---

## Phase 4: GPS Optimization (2-3 days)

### 4.1 Modify Driver GPS Service

**Update:** `lib/services/gps_service.dart`

```dart
import 'socket_service.dart';

class GpsService {
  static Timer? _uploadTimer;
  static Timer? _rtdbBackupTimer;  // ✅ NEW: Slower Firebase backup
  static Position? _lastPosition;
  static Position? _lastBackupPosition;
  static final double _minDistanceMeters = 5.0;  // ✅ Delta compression
  
  /// Start GPS tracking and upload via Socket.io (500ms) + RTDB backup (5s)
  static Future<void> start() async {
    // ... existing permission checks
    
    // ✅ PRIMARY: Socket.io every 500ms
    _uploadTimer = Timer.periodic(
      const Duration(milliseconds: 500),  // ✅ 4x faster than before!
      (_) => _uploadLocationViaSocket(),
    );
    
    // ✅ BACKUP: Firebase RTDB every 5 seconds
    _rtdbBackupTimer = Timer.periodic(
      const Duration(seconds: 5),  // ✅ Reduced from 2s (less Firebase writes)
      (_) => _uploadLocationViaRTDB(),
    );
    
    debugPrint('[GPS] Started: Socket.io 500ms + RTDB 5s backup');
  }
  
  /// Upload location via Socket.io (fast, real-time)
  static Future<void> _uploadLocationViaSocket() async {
    if (_lastPosition == null) return;
    if (!SocketService.isConnected) return;
    
    // ✅ Delta compression: only send if moved >5m
    if (_lastBackupPosition != null) {
      final distance = _haversineDistance(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        _lastBackupPosition!.latitude,
        _lastBackupPosition!.longitude,
      );
      if (distance < _minDistanceMeters) {
        return;  // Skip update, driver hasn't moved
      }
    }
    
    final tripId = _activeTripId;  // Get from state
    if (tripId == null) return;
    
    SocketService.sendDriverLocation(
      tripId: tripId,
      lat: _lastPosition!.latitude,
      lng: _lastPosition!.longitude,
      heading: _lastPosition!.heading,
      speed: _lastPosition!.speed,
    );
    
    _lastBackupPosition = _lastPosition;
  }
  
  /// Upload location via Firebase RTDB (slow backup)
  static Future<void> _uploadLocationViaRTDB() async {
    if (_lastPosition == null || _locRef == null) return;
    
    await _locRef!.set({
      'lat': _lastPosition!.latitude,
      'lng': _lastPosition!.longitude,
      'heading': _lastPosition!.heading,
      'speed': _lastPosition!.speed,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': ServerValue.timestamp,
    });
  }
  
  @override
  static Future<void> stop() async {
    _uploadTimer?.cancel();
    _rtdbBackupTimer?.cancel();
    // ... existing cleanup
  }
}
```

### 4.2 Update Rider Tracking Controller

**Update:** `lib/controllers/rider_tracking_controller.dart`

```dart
extension RiderTrackingController on _RiderTrackingScreenState {
  
  void _startRealTimeTracking() {
    final tripId = widget.tripId;
    if (tripId == null) return;
    
    // ✅ PRIMARY: Socket.io listener (100-200ms latency)
    SocketService.joinTrip(tripId);
    
    _socketLocationSub = SocketService.driverLocationStream.listen((data) {
      if (!mounted || _phase == _TrackPhase.completed) return;
      
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return;
      
      final timestamp = data['timestamp'] as int?;
      if (timestamp != null) {
        final latency = DateTime.now().millisecondsSinceEpoch - timestamp;
        debugPrint('[Socket.io] GPS latency: ${latency}ms');
      }
      
      _onRealDriverLocation(LatLng(lat, lng));
    });
    
    _socketStatusSub = SocketService.tripStatusStream.listen((data) {
      if (!mounted) return;
      final status = data['status']?.toString();
      if (status != null) {
        _onTripStatusUpdate({'status': status});
      }
    });
    
    // ✅ BACKUP: Firebase RTDB listener (fallback if Socket.io drops)
    final fsId = widget.firestoreTripId;
    if (fsId != null) {
      _rtdbBackupSub = FirebaseDatabase.instance
          .ref('drivers/${widget.driverId}/location')
          .onValue
          .listen((event) {
        if (!SocketService.isConnected) {
          // Only use RTDB if Socket.io is down
          final data = event.snapshot.value as Map?;
          if (data == null) return;
          final lat = (data['lat'] as num?)?.toDouble();
          final lng = (data['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) {
            _onRealDriverLocation(LatLng(lat, lng));
          }
        }
      });
    }
    
    // ✅ REMOVE: HTTP polling timer (no longer needed!)
    // _statusPollTimer = Timer.periodic(...);  // DELETE THIS
  }
  
  @override
  void dispose() {
    SocketService.leaveTrip(widget.tripId!);
    _socketLocationSub?.cancel();
    _socketStatusSub?.cancel();
    _rtdbBackupSub?.cancel();
    super.dispose();
  }
}
```

### 4.3 Add Client-Side Interpolation (60fps Smooth Animation)

**Add to** `lib/controllers/rider_tracking_controller.dart`:

```dart
class _RiderTrackingScreenState extends State<RiderTrackingScreen> 
    with TickerProviderStateMixin {
  
  LatLng _targetDriverPos = const LatLng(0, 0);  // ✅ Socket.io target
  LatLng _animatedDriverPos = const LatLng(0, 0);  // ✅ Interpolated position
  double _targetBearing = 0;
  double _animatedBearing = 0;
  Ticker? _interpolationTicker;
  
  @override
  void initState() {
    super.initState();
    
    // ✅ 60fps interpolation ticker
    _interpolationTicker = createTicker(_interpolate)..start();
  }
  
  void _interpolate(Duration elapsed) {
    if (!mounted) return;
    
    // Lerp position (smooth 60fps animation)
    final distance = _haversine(_animatedDriverPos, _targetDriverPos);
    
    if (distance > 0.0001) {  // ~11 meters
      final lerpFactor = 0.15;  // Adjust for smoothness (0.1 = smoother, 0.3 = faster)
      
      setState(() {
        _animatedDriverPos = LatLng(
          _animatedDriverPos.latitude + (_targetDriverPos.latitude - _animatedDriverPos.latitude) * lerpFactor,
          _animatedDriverPos.longitude + (_targetDriverPos.longitude - _animatedDriverPos.longitude) * lerpFactor,
        );
        
        // Lerp bearing
        var bearingDiff = _targetBearing - _animatedBearing;
        if (bearingDiff > 180) bearingDiff -= 360;
        if (bearingDiff < -180) bearingDiff += 360;
        _animatedBearing += bearingDiff * lerpFactor;
      });
    }
  }
  
  void _onRealDriverLocation(LatLng ll) {
    // ✅ Set target - interpolation ticker will animate
    _targetDriverPos = ll;
    
    // Calculate bearing from previous position
    if (_animatedDriverPos.latitude != 0) {
      _targetBearing = _calculateBearing(_animatedDriverPos, ll);
    }
    
    // ... existing distance/ETA calculations
  }
  
  @override
  void dispose() {
    _interpolationTicker?.dispose();
    super.dispose();
  }
}
```

**Success Criteria:**
- GPS updates every 500ms via Socket.io
- Smooth 60fps animation on map
- Fallback to RTDB if Socket.io disconnects
- Latency <200ms measured with timestamps

---

## Phase 5: Trip Status Optimization (2-3 days)

### 5.1 Backend: Emit Trip Status via Socket.io

**Update trip status change endpoints:**

```python
# backend/main.py or backend/routers/trips.py

from services.socketio_service import emit_trip_status

@app.put('/trips/{trip_id}/status')
async def update_trip_status(
    trip_id: int,
    status: str,
    db: AsyncSession = Depends(get_db),
):
    # ✅ Update database
    result = await db.execute(
        select(Trip).where(Trip.id == trip_id)
    )
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, 'Trip not found')
    
    trip.status = status
    await db.commit()
    
    # ✅ Emit Socket.io event FIRST (instant notification)
    await emit_trip_status(
        trip_id=trip_id,
        status=status,
        extra={'driver_id': trip.driver_id, 'rider_id': trip.rider_id},
    )
    
    # ✅ Update Firestore in parallel (don't wait for confirmation)
    asyncio.create_task(_update_firestore_async(trip_id, status))
    
    return {'status': 'success', 'trip_id': trip_id, 'new_status': status}

async def _update_firestore_async(trip_id: int, status: str):
    """Non-blocking Firestore update."""
    try:
        if firestore_sync:
            firestore_sync.update_trip(trip_id, {'status': status})
    except Exception as e:
        logging.error(f'Firestore update failed for trip {trip_id}: {e}')
```

### 5.2 Flutter: Optimistic UI Updates

**Update trip action methods:**

```dart
// lib/state/rider_trip_controller.dart

Future<void> cancelTrip() async {
  final tripId = _state.tripId;
  if (tripId == null) return;
  
  // ✅ OPTIMISTIC: Update UI immediately
  _state = _state.copyWith(
    phase: RiderPhase.cancelled,
    cancelReason: 'Cancelling trip...',
  );
  notifyListeners();
  
  try {
    // ✅ Send cancellation to backend
    await ApiService.cancelTrip(tripId);
    
    // ✅ Success: Keep optimistic state
    _state = _state.copyWith(cancelReason: 'Trip cancelled');
    notifyListeners();
  } catch (e) {
    // ✅ ROLLBACK: Revert to previous state on error
    _state = _state.copyWith(
      phase: _previousPhase,  // Store previous phase
      cancelReason: null,
    );
    notifyListeners();
    
    // Show error to user
    debugPrint('[Trip] Cancellation failed: $e');
    // TODO: Show snackbar with error message
  }
}
```

### 5.3 Remove Redundant Polling

**Delete or comment out HTTP polling timers:**

```dart
// lib/controllers/rider_tracking_controller.dart

void _startRealTimeTracking() {
  // ✅ Socket.io listeners only
  SocketService.joinTrip(tripId);
  _socketLocationSub = SocketService.driverLocationStream.listen(...);
  _socketStatusSub = SocketService.tripStatusStream.listen(...);
  
  // ❌ DELETE: No longer needed!
  // _statusPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
  //   final status = await ApiService.getTrip(tripId);
  //   ...
  // });
}

// lib/state/rider_trip_controller.dart
void _searchForDriver() {
  // ... existing code
  
  // ❌ DELETE: Replace with Socket.io listener for driver assignments
  // _pollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
  //   final status = await ApiService.getDispatchStatus(tripId);
  //   ...
  // });
  
  // ✅ NEW: Listen for driver assignment via Socket.io
  _socketStatusSub = SocketService.tripStatusStream
      .where((data) => data['trip_id'] == _state.tripId)
      .listen((data) {
        final status = data['status']?.toString();
        if (status == 'driver_assigned') {
          _onDriverAssigned(data['driver_id']);
        }
      });
}
```

**Success Criteria:**
- All status changes via Socket.io (<100ms)
- Optimistic UI updates (instant feedback)
- Firestore as backup only (parallel writes, no reads)
- Zero HTTP polling timers for trip status

---

## Phase 6: Login & Startup Optimization (1-2 days)

### 6.1 Cached UI First, Verify in Background

**Update:** `lib/services/user_session.dart`

```dart
class UserSession {
  static bool _isVerifyingAuth = false;
  
  /// Fast check: Read cached user without network call
  static Future<bool> isLoggedInCached() async {
    final token = await getAuthToken();
    if (token == null || token.isEmpty) return false;
    
    final user = await getUser();  // Local SharedPreferences read (<10ms)
    return user != null && user['id'] != null;
  }
  
  /// Slow check: Verify with backend (background task)
  static Future<bool> verifyAuthInBackground() async {
    if (_isVerifyingAuth) return true;  // Already running
    
    _isVerifyingAuth = true;
    
    try {
      final profile = await ApiService.getProfile();
      if (profile != null) {
        // Update cached user with fresh data
        await saveUser(profile);
        return true;
      } else {
        // Token invalid - clear session
        await logout();
        return false;
      }
    } catch (e) {
      debugPrint('[Auth] Background verification failed: $e');
      // Network error - keep cached session for now
      return true;
    } finally {
      _isVerifyingAuth = false;
    }
  }
}
```

**Update:** `lib/screens/splash_screen.dart`

```dart
class SplashScreen extends StatefulWidget {
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _init();
  }
  
  Future<void> _init() async {
    final stopwatch = Stopwatch()..start();
    
    // ✅ Parallel initialization (no sequential blocking)
    await Future.wait([
      NotificationService.init(),
      LocalDataService.init(),
      MapCacheService.init(),
      SocketService.init(),
    ]);
    
    print('[Splash] Services initialized: ${stopwatch.elapsedMilliseconds}ms');
    
    // ✅ FAST: Check cached auth (<10ms)
    final hasCache = await UserSession.isLoggedInCached();
    
    if (hasCache) {
      // ✅ Show home screen immediately with cached data
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => HomeScreen(),
          transitionDuration: Duration.zero,  // Instant transition
        ),
      );
      
      // ✅ SLOW: Verify auth in background (don't block UI)
      _verifyAuthInBackground();
    } else {
      // No cached user - show login screen
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => LoginScreen(),
          transitionDuration: Duration.zero,
        ),
      );
    }
    
    print('[Splash] Navigation: ${stopwatch.elapsedMilliseconds}ms');
  }
  
  void _verifyAuthInBackground() async {
    final isValid = await UserSession.verifyAuthInBackground();
    
    if (!isValid && mounted) {
      // Token expired - force logout
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => LoginScreen()),
      );
      
      // Show message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Session expired. Please log in again.')),
      );
    }
  }
}
```

### 6.2 Preload Critical Data in Parallel

**Update:** `lib/screens/home_screen.dart`

```dart
@override
void initState() {
  super.initState();
  
  // ✅ Parallel preloading (don't await sequentially!)
  Future.wait([
    _loadRecentTrips(),
    _loadFavoriteLocations(),
    _loadPaymentMethods(),
    _loadActivePromos(),
  ]).then((_) {
    setState(() => _dataLoaded = true);
  });
}

Future<void> _loadRecentTrips() async {
  try {
    final trips = await ApiService.getRecentTrips(limit: 5);
    if (mounted) setState(() => _recentTrips = trips);
  } catch (e) {
    debugPrint('[Home] Failed to load trips: $e');
    // Show cached trips instead
    _recentTrips = await LocalCache.getRecentTrips();
  }
}
```

### 6.3 Remove Blocking Initialization

**Update:** `lib/main.dart`

```dart
void main() async {
  final stopwatch = Stopwatch()..start();
  
  WidgetsFlutterBinding.ensureInitialized();
  print('[Init] Binding: ${stopwatch.elapsedMilliseconds}ms');
  
  // ✅ FAST: Critical sync init only
  await SecurityService.init();
  print('[Init] Security: ${stopwatch.elapsedMilliseconds}ms');
  
  // ✅ FAST: Firebase init with timeout
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  ).timeout(
    const Duration(seconds: 2),
    onTimeout: () {
      debugPrint('[Init] Firebase timeout - continuing anyway');
      return Firebase.app();  // Return default app
    },
  );
  print('[Init] Firebase: ${stopwatch.elapsedMilliseconds}ms');
  
  // ✅ FAST: ApiService init (non-blocking Firestore read with cache-first)
  await ApiService.init();
  print('[Init] ApiService: ${stopwatch.elapsedMilliseconds}ms');
  
  // ✅ Show app immediately
  runApp(CruiseApp());
  print('[Init] runApp: ${stopwatch.elapsedMilliseconds}ms');
  
  // ⚠️ Target: <500ms to runApp()
}
```

**Success Criteria:**
- App shows cached UI in <800ms (cold start)
- Login flow completes in <1,000ms (cache read + network verify)
- Background auth verification doesn't block UI
- Smooth transition even on slow networks

---

## Testing & Rollout Strategy

### 7.1 A/B Testing Configuration

**Create feature flag:** `lib/config/feature_flags.dart`

```dart
class FeatureFlags {
  static bool get useSocketIO {
    // TODO: Read from Firebase Remote Config
    return _overrideSocketIO ?? _defaultSocketIO;
  }
  
  static bool _defaultSocketIO = false;  // ✅ False until rollout
  static bool? _overrideSocketIO;
  
  /// Force enable/disable for testing
  static void setSocketIOOverride(bool enabled) {
    _overrideSocketIO = enabled;
  }
}
```

**Update GPS service:**

```dart
static Future<void> start() async {
  if (FeatureFlags.useSocketIO) {
    // ✅ NEW: Socket.io path
    _uploadTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _uploadLocationViaSocket(),
    );
  } else {
    // ❌ OLD: Firebase RTDB path
    _uploadTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _uploadLocationViaRTDB(),
    );
  }
}
```

### 7.2 Gradual Rollout Plan

**Week 1:** Internal testing (10% of users)
- Enable Socket.io for beta testers only
- Monitor latency metrics in Firebase Analytics
- Check for crashes/errors in Crashlytics

**Week 2:** Expanded rollout (50% of users)
- A/B test: 50% Socket.io, 50% Firebase RTDB
- Compare latency distributions (p50, p95, p99)
- Check battery usage (Firebase Performance Monitoring)

**Week 3:** Full rollout (100% of users)
- Enable Socket.io for all users
- Keep Firebase RTDB as backup (monitor fallback rate)
- Remove HTTP polling timers

**Week 4:** Cleanup
- Remove old Firebase RTDB code paths
- Update documentation
- Celebrate 🎉

### 7.3 Monitoring & Alerting

**Add to Firebase Analytics:**

```dart
AnalyticsService.logEvent('gps_update_latency', {
  'latency_ms': latency,
  'source': 'socketio',  // or 'rtdb_fallback'
  'trip_id': tripId.toString(),
});

AnalyticsService.logEvent('trip_status_update_latency', {
  'latency_ms': latency,
  'status': status,
  'trip_id': tripId.toString(),
});

AnalyticsService.logEvent('app_cold_start', {
  'time_to_first_frame_ms': duration,
  'network_type': networkType,
});
```

**Backend Monitoring:**

```python
# backend/services/socketio_service.py

# Log Socket.io metrics
logger.info(f'[Metrics] Active connections: {len(sio.manager.rooms)}')
logger.info(f'[Metrics] Drivers online: {len(active_connections["drivers"])}')
logger.info(f'[Metrics] Active trips: {len([r for r in sio.manager.rooms if r.startswith("trip:")])}')
```

**Set up alerts:**
- GPS latency >500ms for 5+ consecutive updates
- Socket.io disconnect rate >5%
- App cold start >1,500ms

---

## Rollback Plan

### If Socket.io Fails

**Emergency rollback in <5 minutes:**

```dart
// lib/config/feature_flags.dart

class FeatureFlags {
  // ✅ Change from true to false
  static bool _defaultSocketIO = false;  // ROLLBACK!
}

// Push update via Firebase Remote Config (instant rollback without app update)
```

**Fallback behavior:**
- GPS reverts to Firebase RTDB (2s intervals)
- Trip status reverts to Firestore snapshots
- HTTP polling timers re-enabled

**Success criteria for rollback:**
- All users revert to old behavior within 10 minutes
- No crashes or data loss
- Metrics return to baseline

---

## Success Metrics

### Phase 2 (Profiling)
- ✅ Measure baseline latencies
- ✅ Identify memory leaks
- ✅ Document initialization bottlenecks

### Phase 3 (Socket.io Infrastructure)
- ✅ Socket.io server running on backend
- ✅ Flutter client connects successfully
- ✅ Room-based broadcasting working
- ✅ Authentication flow complete

### Phase 4 (GPS Optimization)
- ✅ GPS updates every 500ms via Socket.io
- ✅ Latency <200ms (p50)
- ✅ Smooth 60fps animation on map
- ✅ Firebase RTDB backup working

### Phase 5 (Trip Status Optimization)
- ✅ Status updates via Socket.io (<100ms)
- ✅ Optimistic UI updates implemented
- ✅ HTTP polling removed
- ✅ Firestore as backup only

### Phase 6 (Login Optimization)
- ✅ App cold start <800ms
- ✅ Login flow <1,000ms
- ✅ Cached UI shown immediately
- ✅ Background auth verification

### Final Target Metrics
- **Driver GPS → Rider:** <200ms (p95)
- **Trip status updates:** <100ms (p95)
- **App cold start:** <800ms (p95)
- **Login flow:** <1,000ms (p95)
- **Battery usage:** -20% vs baseline
- **Network usage:** -30% vs baseline

---

## Timeline Summary

| Phase | Duration | Key Deliverables |
|-------|----------|------------------|
| Phase 2: Profiling | 1-2 days | Baseline metrics, memory leak report |
| Phase 3: Socket.io Setup | 3-5 days | Backend server, Flutter client, authentication |
| Phase 4: GPS Optimization | 2-3 days | 500ms updates, interpolation, fallback |
| Phase 5: Trip Status | 2-3 days | Socket.io status, optimistic UI, polling removal |
| Phase 6: Login Optimization | 1-2 days | Cached UI, background verification |
| Testing & Rollout | 7-14 days | A/B testing, gradual rollout, monitoring |
| **Total** | **3-4 weeks** | Production-ready Socket.io architecture |

---

**Document Created:** January 2025  
**Status:** Implementation Ready  
**Next Action:** Begin Phase 2 (Performance Profiling)
